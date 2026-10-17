#!/usr/bin/env python3
"""Short manual macOS observations; never a CI performance gate.

The comparison renderer is extracted from a specified historical revision into
an ignored output folder. No legacy renderer is maintained in product sources.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
UI = "app/Packages/TetherFrontend/Sources/TetherUI/"


def command(*args, **kwargs):
    return subprocess.run(list(map(str, args)), cwd=ROOT, check=True, **kwargs)


def source(revision, name):
    return command("git", "show", revision + ":" + UI + name,
                   capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="Git revision containing the Swift Metal renderer")
    parser.add_argument("--output", required=True, type=Path, help="New evidence directory; existing paths are refused")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Apple observations require macOS with a Metal device")
    artifact = ROOT / "swift/Artifacts/TetherFFI.xcframework/macos-arm64/libtether_ffi.a"
    if not artifact.exists():
        parser.error("Build scripts/build-xcframework.sh before evaluating")
    revision = command("git", "rev-parse", "--verify", "--end-of-options", args.baseline + "^{commit}",
                       capture_output=True, text=True).stdout.strip()
    metal = source(revision, "MetalTerminal.swift")
    palette = source(revision, "Palette.swift")
    view = source(revision, "TerminalView.swift")
    # This harness targets the historical renderer's concrete API, not a
    # permanent renderer framework. Unsupported baselines fail explicitly.
    metrics = view[view.index("public struct FontMetrics:"):view.index("/// Pictures of rows")]
    metrics += view[view.index("private final class FontMetricsCache:"):]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    project = output / "baseline"
    swift = project / "Sources/Compare"
    swift.mkdir(parents=True)
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RenderCompare", platforms: [.macOS(.v26)], dependencies: [
.package(path: %s)], targets: [.executableTarget(name: "Compare", dependencies: [.product(name: "Tether", package: "swift")])])
''' % json.dumps(str(ROOT / "swift"), ensure_ascii=False)
    (project / "Package.swift").write_text(manifest)
    metal += '''
// Evaluation only: reuse the original encoder and wait outside the CPU span.
extension TerminalMetalView {
  func submitForEvaluation(target: MTLTexture, points: SIMD2<Float>) -> MTLCommandBuffer? {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].storeAction = .store
    guard let command = encode(into: pass, points: points) else { return nil }
    command.commit()
    return command
  }
}
'''
    (swift / "MetalTerminal.swift").write_text(metal)
    (swift / "Palette.swift").write_text(palette)
    (swift / "FontMetrics.swift").write_text("import SwiftUI\nimport AppKit\n" + metrics)
    (swift / "Main.swift").write_text((ROOT / "testing/apple-renderer/Main.swift").read_text())
    with (output / "build.log").open("w") as log:
        command("swift", "build", "--package-path", project, "-c", "release", stdout=log, stderr=log)
    binary = project / ".build/release/Compare"
    observations = {}
    for renderer in ("metal", "wgpu"):
        with (output / (renderer + ".json")).open("w") as result, (output / (renderer + "-resources.txt")).open("w") as resources:
            command("/usr/bin/time", "-l", binary, renderer, output, stdout=result, stderr=resources)
        observations[renderer] = json.loads((output / (renderer + ".json")).read_text())
    report = {
        "baseline_revision": revision,
        "current_revision": command("git", "rev-parse", "HEAD", capture_output=True, text=True).stdout.strip(),
        "native_artifact_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
        "harness_sha256": hashlib.sha256((swift / "Main.swift").read_bytes()).hexdigest(),
        "source_hashes": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for base in (ROOT / "crates/tether-render/src", ROOT / "crates/tether-ffi/src")
                          for path in base.rglob("*.rs")},
        "os": command("sw_vers", "-productVersion", capture_output=True, text=True).stdout.strip(),
        "cpu": command("sysctl", "-n", "machdep.cpu.brand_string", capture_output=True, text=True).stdout.strip(),
        "observations": observations,
        "displayed_fps": None, "gpu_pass_ms": None, "power": None,
        "limitations": "20 short samples after 3 warmup draws; CPU spans can include driver waits. Offscreen GPU completion is not presentation latency; screenshot readback is collected separately. Source revision alone does not prove native artifact provenance. No performance pass/fail thresholds.",
    }
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Collected observations:", output)


if __name__ == "__main__":
    main()
