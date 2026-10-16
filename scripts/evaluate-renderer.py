"""Collect optional, hardware-dependent Release HWND/FFI observations.

Performance is informational and never a CI pass/fail criterion.

No downloads, elevation, OS setting changes or generated-binding edits.
"""
import argparse
import csv
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
TFM = "net10.0-windows10.0.22621.0"


def run(*args):
    print("+ " + " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def summary(values):
    values = sorted(values)
    if not values:
        return None
    return {name: values[min(len(values) - 1, math.ceil(len(values) * p) - 1)]
            for name, p in (("p50", .5), ("p95", .95), ("p99", .99), ("max", 1))}


def analyze_native(folder, result):
    stages = defaultdict(list)
    indexed = defaultdict(list)
    trace = folder / "native.csv"
    if trace.exists():
        with trace.open(encoding="utf-8") as stream:
            for row in csv.reader(stream):
                stage, value = row[:2]
                stages[stage].append(float(value))
                if len(row) == 3:
                    indexed[stage].append((int(row[2]), float(value)))
    warm = result["warmup_draws"]
    count = result["draws"]
    measured = {stage: values[warm:warm + count] for stage, values in stages.items()
                if stage.endswith("_ms") and stage != "gpu_pass_ms"}
    # GPU callbacks can complete after the next CPU frame. GPU percentiles are
    # reported independently, never added to CPU p95s to invent frame latency.
    measured["gpu_pass_ms"] = stages.get("gpu_pass_ms", [])[warm:warm + count]
    for stage, values in indexed.items():
        if stage.endswith("_ms"):
            measured[stage] = [value for frame, value in values if warm < frame <= warm + count]
    native = measured.get("native_draw_ms", [])
    managed = []
    with (folder / "calls.csv").open(encoding="utf-8") as stream:
        managed = [float(row["managed_draw_ms"]) for row in csv.DictReader(stream)]
    if len(native) == len(managed):
        measured["managed_and_ffi_overhead_ms"] = [max(0, a - b) for a, b in zip(managed, native)]
    layout = measured.get("metrics_conversion_layout_ms", [])
    # Legacy traces combine conversion and layout. Current hosts only convert
    # DTOs; the shared renderer owns metrics/layout and reports it separately.
    if "metrics_layout_ms" in measured:
        metrics = measured["metrics_layout_ms"]
        conversion = measured.get("frame_conversion_ms", [])
        layout = [a + b for a, b in zip(metrics, conversion)] if len(metrics) == len(conversion) else []
    render = measured.get("render_cpu_work_ms", [])
    if len(layout) == len(render) == count:
        measured["cpu_render_work_ms"] = [a + b for a, b in zip(layout, render)]
        overhead = measured.get("managed_and_ffi_overhead_ms", [])
        if len(overhead) == count:
            measured["cpu_work_including_ffi_ms"] = [a + b + c for a, b, c in zip(layout, render, overhead)]
    errors = {stage: len(values) for stage, values in stages.items() if not stage.endswith("_ms")}
    return {"stages": {stage: {"count": len(values), "ms": summary(values)}
                        for stage, values in measured.items()}, "events": errors}


def analyze_presents(path, result):
    """PresentMon v2 QPC CSV. Select displayed frames, PID and swapchain.

    Reconstruct display QPC from CPU start + DisplayLatency; this avoids
    measuring submission intervals or treating dropped frames as displayed.
    Never combine different swapchains into a single cadence.
    """
    missing = {"status": "unverified", "reason": "no valid displayed-frame ETW samples"}
    if not path.exists():
        return missing
    chains = defaultdict(list)
    frequency = result["qpc_frequency"]
    begin, end = result["measurement_start_qpc"], result["measurement_end_qpc"]
    with path.open(encoding="utf-8-sig") as stream:
        for row in csv.DictReader(stream):
            if row.get("ProcessID") != str(result["pid"]):
                continue
            try:
                start = int(row["CPUStartQPC"])
                latency = float(row["DisplayLatency"])
                displayed_time = float(row["DisplayedTime"])
                if not math.isfinite(latency) or not math.isfinite(displayed_time) or displayed_time <= 0 or latency < 0 or not begin <= start <= end:
                    continue
                displayed = start + latency * frequency / 1000
                chains[row["SwapChainAddress"]].append(displayed)
            except (KeyError, ValueError):
                continue
    if len(chains) != 1:
        return missing | {"reason": "expected exactly one measured swapchain", "chains": len(chains)}
    stamps = sorted(next(iter(chains.values())))
    intervals = [(b - a) * 1000 / frequency for a, b in zip(stamps, stamps[1:])]
    if len(intervals) < max(2, result["requested_seconds"] * 30):
        return missing | {"reason": "insufficient displayed-frame coverage", "intervals": len(intervals)}
    misses = sum(value > 33.3 for value in intervals)
    return {"status": "observed",
            "interval_ms": summary(intervals), "intervals": len(intervals),
            "over_33_3_ms": misses, "over_33_3_fraction": misses / len(intervals)}


def analyze_snapshot(folder, result):
    path = folder / "snapshot.ppm"
    if not path.exists():
        return {"status": "unverified", "reason": "swapchain readback missing"}
    magic, dimensions, maximum, pixels = path.read_bytes().split(b"\n", 3)
    width, height = map(int, dimensions.split())
    if magic != b"P6" or maximum != b"255" or len(pixels) != width * height * 3:
        return {"status": "fail", "reason": "invalid PPM readback"}
    if (width, height) != (result["physical_surface"]["width"], result["physical_surface"]["height"]):
        return {"status": "fail", "reason": "readback dimensions differ from configured surface"}
    pitch = width // result["columns"]
    # Font fixtures put a visible | in the final column. The preceding cell
    # is blank, outside selection/link overlays, and supplies the background.
    background = pixels[(width - 2 * pitch + 1) * 3: (width - 2 * pitch + 1) * 3 + 3]
    def ink(x, y):
        offset = (y * width + x) * 3
        return any(abs(a - b) > 10 for a, b in zip(pixels[offset:offset + 3], background))
    rows_with_ink = sum(any(ink(x, y)
        for y in range(row * height // result["rows"], math.ceil((row + 1) * height / result["rows"]))
        for x in range(width - pitch, width)) for row in range(result["rows"]))
    return {"status": "pass" if rows_with_ink == result["rows"] else "fail",
            "right_edge_rows_with_ink": rows_with_ink, "expected_rows": result["rows"],
            "note": "Grid-boundary smoke check only; font quality still needs visual review"}


def assess(folder):
    result = json.loads((folder / "result.json").read_text(encoding="utf-8"))
    native = analyze_native(folder, result)
    present = analyze_presents(folder / "presentmon.csv", result)
    adapter = (folder / "adapter.txt").read_text(encoding="utf-8") if (folder / "adapter.txt").exists() else ""
    hardware = any(kind in adapter for kind in ("device_type: DiscreteGpu", "device_type: IntegratedGpu"))
    count = result["draws"]
    stages = native["stages"]
    cpu = stages.get("cpu_render_work_ms", {})
    # Exclude swapchain acquisition/present waits from CPU work.
    # GPU pass time is separate; ETW can optionally observe display cadence.
    work = stages.get("cpu_work_including_ffi_ms", {})
    cpu_status = "unverified" if count == 0 or not cpu.get("ms") or not work.get("ms") else "observed"
    if result.get("cancelled") or result["measured_seconds"] < result["requested_seconds"] * .99 or "backend: Dx12" not in adapter or not hardware:
        cpu_status = "unverified"
    gpu_samples = []
    if (folder / "gpu-engine.jsonl").exists():
        for line in (folder / "gpu-engine.jsonl").read_text(encoding="utf-8-sig").splitlines():
            sample = json.loads(line)
            # Keep per-engine values: summing engines is not GPU utilization.
            if result["measurement_start_qpc"] <= sample.get("qpc", -1) <= result["measurement_end_qpc"]:
                gpu_samples.append(sample)
    evidence = {"scenario": folder.name, "result": result, "native": native,
                "dx12": "backend: Dx12" in adapter, "hardware_gpu": hardware, "cpu_observation": cpu_status,
                "actual_present": present, "gpu_pass_measured": stages.get("gpu_pass_ms", {}).get("count", 0) > 0,
                "gpu_engine_samples": gpu_samples,
                "gpu_warmup_filter": "frame_id" if indexed_trace(folder) else "legacy_sample_order_approximation",
                "grid_boundary": analyze_snapshot(folder, result) if result["mode"] == "snapshot" else None,
                "visual_review": "unverified", "device_loss": "unverified"}
    (folder / "assessment.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    return evidence


def indexed_trace(folder):
    path = folder / "native.csv"
    if not path.exists():
        return False
    with path.open(encoding="utf-8") as stream:
        return len(next(csv.reader(stream), [])) == 3


def decision(results):
    for evidence in results:
        if (evidence.get("grid_boundary") or {}).get("status") == "fail":
            return "issues found; fix and remeasure before an Apple prototype"
    return "informational hardware observations; Apple comparison remains a separate decision"


def source_digest():
    paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT)
    digest = hashlib.sha256()
    for name in sorted(paths.split(b"\0")):
        if name:
            path = ROOT / os.fsdecode(name)
            if path.is_file():
                digest.update(name + b"\0" + path.read_bytes())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--group", choices=("common", "stress", "snapshots", "lifecycle"), default="common")
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--smoke", action="store_true", help="Quick 2s x 1 observation")
    parser.add_argument("--full-matrix", action="store_true", help="Also sample static, cursor and single-row modes")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--native-library", type=Path, help="Explicit previously built diagnostic DLL (use with --skip-build)")
    parser.add_argument("--gpu-counters", action="store_true", help="Collect process-specific GPU engine counters in a sidecar")
    parser.add_argument("--presentmon", type=Path, help="Existing console exe; no elevation is attempted")
    parser.add_argument("--analyze", type=Path, help="Re-analyze one completed scenario, without running anything")
    parser.add_argument("--analyze-run", type=Path, help="Re-analyze all completed scenarios in a run")
    args = parser.parse_args()
    if args.analyze:
        print(json.dumps(assess(args.analyze), indent=2))
        return
    if args.analyze_run:
        results = [assess(path.parent) for path in sorted(args.analyze_run.glob("*/result.json"))]
        summary_path = args.analyze_run / "summary.json"
        metadata = json.loads(summary_path.read_text(encoding="utf-8")) if summary_path.exists() else {}
        metadata.pop("requested_acceptance_protocol", None)
        metadata.update(purpose="informational performance sampling; not a CI gate", decision=decision(results), scenarios=results)
        summary_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        print(f"Re-analyzed {len(results)} scenarios")
        return
    if sys.platform != "win32":
        parser.error("Real Windows hardware and HWND required")
    if args.seconds <= 0 or args.repetitions < 1:
        parser.error("seconds and repetitions must be positive")
    if args.native_library and not args.skip_build:
        parser.error("--native-library requires --skip-build; otherwise use the freshly built DLL")
    output = (args.output or ROOT / "artifacts/windows-render-evaluation" / time.strftime("%Y%m%d-%H%M%S")).resolve()
    output.mkdir(parents=True, exist_ok=False)
    if not args.skip_build:
        run("cargo", "build", "--locked", "--release", "-p", "tether-ffi", "--features", "render-diagnostics", "--lib")
        run("dotnet", "build", "tests/render-evaluation", "-c", "Release", "-warnaserror")
    source = ROOT / "tests/render-evaluation/bin/Release" / TFM
    executable = source / "RenderEvaluation.exe"
    # Isolate native DLLs from ordinary builds and other evaluation processes.
    binary = output / "bin"
    shutil.copytree(source, binary)
    target = Path(os.environ.get("CARGO_TARGET_DIR", ROOT / "target"))
    if not target.is_absolute():
        target = ROOT / target
    shutil.copy2(args.native_library or target / "release/tether_ffi.dll", binary / "tether_ffi.dll")
    executable = binary / executable.name
    machine = subprocess.run(["powershell", "-NoProfile", "-Command",
        "Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate | ConvertTo-Json"],
        capture_output=True, text=True, check=True).stdout
    (output / "video-controller.json").write_text(machine, encoding="utf-8")
    (output / "provenance.json").write_text(json.dumps({
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "build_performed": not args.skip_build,
        "dirty_diff_sha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)).hexdigest(),
        "source_files_sha256": source_digest(),
        "native_sha256": hashlib.sha256((binary / "tether_ffi.dll").read_bytes()).hexdigest(),
        "harness_sha256": hashlib.sha256((binary / "RenderEvaluation.dll").read_bytes()).hexdigest(),
        "presentmon_sha256": hashlib.sha256(args.presentmon.read_bytes()).hexdigest() if args.presentmon else None,
        "arguments": {key: str(value) for key, value in vars(args).items()},
        "provenance_note": "Source state is recorded at collection time. With --skip-build, binary hashes identify supplied artifacts; a source hash does not establish their build provenance.",
    }, indent=2), encoding="utf-8")
    sizes = [(80, 24), (120, 40), (200, 60)]
    shapes = ["prose", "highlighted"]
    modes = ["static", "cursor", "line", "scroll"] if args.full_matrix else ["scroll"]
    scales = [1.0]
    if args.group == "stress":
        sizes += [(400, 100)]
        shapes = ["prose", "highlighted", "worstCase"]
    elif args.group == "snapshots":
        sizes, shapes, modes, scales = sizes + [(400, 100)], ["fonts"], ["snapshot"], [1.0, 1.5, 2.0]
    elif args.group == "lifecycle":
        sizes, shapes, modes = [(120, 40)], ["fonts"], ["lifecycle"]
    seconds, repetitions = (2, 1) if args.smoke else (args.seconds, args.repetitions)
    expected = sum(1 for columns, _ in sizes for shape in shapes
                   if not (args.group == "stress" and shape != "worstCase" and columns != 400)
                   for mode in modes for _ in scales
                   for _ in range(1 if mode == "snapshot" else repetitions))
    results = []
    for columns, rows in sizes:
        for shape in shapes:
            if args.group == "stress" and shape != "worstCase" and columns != 400:
                continue
            for mode in modes:
                for scale in scales:
                    for repetition in range(repetitions if mode != "snapshot" else 1):
                        name = f"{columns}x{rows}-{shape}-{mode}-{scale}-{repetition + 1}"
                        folder = output / name
                        folder.mkdir()
                        monitor = None
                        with (folder / "presentmon.log").open("w", encoding="utf-8") as log:
                            if args.presentmon and mode not in ("snapshot", "static"):
                                monitor = subprocess.Popen([str(args.presentmon.resolve()), "--process_name", executable.name,
                                    "--session_name", f"TetherEvaluation-{os.getpid()}", "--v2_metrics", "--qpc_time",
                                    "--output_file", str(folder / "presentmon.csv"), "--no_console_stats", "--terminate_on_proc_exit",
                                    "--timed", str(math.ceil(seconds + 20)), "--terminate_after_timed"], stdout=log, stderr=log)
                                time.sleep(.5)
                            try:
                                command = list(map(str, [executable, "--output", folder, "--columns", columns, "--rows", rows,
                                    "--shape", shape, "--mode", mode, "--seconds", seconds, "--scale", scale]))
                                print("+ " + " ".join(command), flush=True)
                                process = subprocess.Popen(command, cwd=ROOT)
                                counter = None
                                if args.gpu_counters and mode != "snapshot":
                                    counter = subprocess.Popen(["powershell", "-NoProfile", "-File",
                                        str(ROOT / "scripts/sample-render-gpu.ps1"), "-ProcessId", str(process.pid),
                                        "-Output", str(folder / "gpu-engine.jsonl"), "-MaxSeconds", str(math.ceil(seconds + 60))],
                                        stdout=log, stderr=log)
                                try:
                                    code = process.wait(timeout=seconds + 120)
                                    if code == 3:
                                        (output / "summary.json").write_text(json.dumps({
                                            "complete": False, "status": "cancelled", "decision": "benchmark window closed; no further scenarios started",
                                            "scenarios": results,
                                        }, indent=2), encoding="utf-8")
                                        raise SystemExit(3)
                                    if code == 2 and (folder / "gpu-unverified.json").exists():
                                        (output / "summary.json").write_text(json.dumps({
                                            "complete": False, "status": "unverified", "decision": "GPU initialization unavailable; defer evaluation",
                                            "diagnostic": json.loads((folder / "gpu-unverified.json").read_text(encoding="utf-8")),
                                            "scenarios": results,
                                        }, indent=2), encoding="utf-8")
                                        raise SystemExit(2)
                                    if code:
                                        raise subprocess.CalledProcessError(code, command)
                                except subprocess.TimeoutExpired:
                                    process.kill()
                                    process.wait()
                                    raise
                                finally:
                                    if counter:
                                        counter.wait(timeout=65)
                            finally:
                                if monitor:
                                    # A bounded timed capture owns its ETW session. Let it
                                    # clean up instead of killing it and leaking the session.
                                    monitor.wait(timeout=seconds + 25)
                        evidence = assess(folder)
                        results.append(evidence)
                        if not evidence["dx12"] or not evidence["hardware_gpu"]:
                            (output / "summary.json").write_text(json.dumps({
                                "complete": False, "status": "unverified",
                                "decision": "DX12 hardware adapter evidence unavailable; measurements unverified",
                                "scenarios": results,
                            }, indent=2), encoding="utf-8")
                            raise SystemExit(2)
                        print(f"{name}: CPU={evidence['cpu_observation']}, present={evidence['actual_present']['status']}", flush=True)
                        (output / "summary.json").write_text(json.dumps({
                            "purpose": "informational performance sampling; not a CI gate",
                            "complete": len(results) == expected, "expected_scenarios": expected,
                            "decision": decision(results),
                            "scenarios": results,
                        }, indent=2), encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
