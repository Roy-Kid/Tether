"""Regression tests for evaluation evidence; deliberately requires no GPU."""
import importlib.util
import csv
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("evaluation", Path(__file__).with_name("evaluate-renderer.py"))
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class EvidenceTests(unittest.TestCase):
    def test_missing_trace_never_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(evaluation.analyze_presents(Path(directory) / "missing.csv", {})["status"], "unverified")

    def present(self, *, gap=16, extra_chain=False, missing_column=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "present.csv"
            with path.open("w", newline="", encoding="utf-8") as stream:
                fields = ["ProcessID", "SwapChainAddress", "CPUStartQPC", "DisplayLatency", "DisplayedTime"]
                if missing_column:
                    fields[2] = "TimeInSeconds"
                writer = csv.writer(stream)
                writer.writerow(fields)
                # 64 frames: enough for a one-second synthetic capture.
                stamp = 1_000_000
                for index in range(64):
                    stamp += gap if index == 32 else 16
                    writer.writerow([123, "0x1", stamp, 1, 16])
                    # Wrong PID and dropped events must not enter cadence.
                    writer.writerow([456, "0x2", stamp, 1, 16])
                    writer.writerow([123, "0x1", stamp + 1, "NA", "NA"])
                if extra_chain:
                    writer.writerow([123, "0x2", stamp, 1, 16])
            return evaluation.analyze_presents(path, {
                "pid": 123, "qpc_frequency": 1000, "measurement_start_qpc": 1_000_000,
                "measurement_end_qpc": 1_010_000, "requested_seconds": 1,
            })

    def test_displayed_frames_are_observations_with_valid_coverage(self):
        self.assertEqual(self.present()["status"], "observed")

    def test_dropped_frame_creates_real_display_gap(self):
        result = self.present(gap=50)
        self.assertEqual(result["status"], "observed")
        self.assertEqual(result["over_33_3_ms"], 1)

    def test_multiple_swapchains_are_not_combined(self):
        self.assertEqual(self.present(extra_chain=True)["status"], "unverified")

    def test_unknown_time_units_are_not_guessed(self):
        self.assertEqual(self.present(missing_column=True)["status"], "unverified")

    def test_native_warmup_and_ffi_are_separated(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "native.csv").write_text(
                "native_draw_ms,100\nmetrics_conversion_layout_ms,90\nrender_cpu_work_ms,10\n"
                "native_draw_ms,12\nmetrics_conversion_layout_ms,1\nrender_cpu_work_ms,2\n", encoding="utf-8")
            (folder / "calls.csv").write_text("managed_draw_ms\n14\n", encoding="utf-8")
            result = evaluation.analyze_native(folder, {"warmup_draws": 1, "draws": 1})
            self.assertEqual(result["stages"]["cpu_work_including_ffi_ms"]["ms"]["p95"], 5)

    def test_shared_renderer_layout_and_binding_conversion_both_count(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "native.csv").write_text(
                "native_draw_ms,12,1\nframe_conversion_ms,1,1\nmetrics_layout_ms,2,1\nrender_cpu_work_ms,3,1\n",
                encoding="utf-8")
            (folder / "calls.csv").write_text("managed_draw_ms\n14\n", encoding="utf-8")
            result = evaluation.analyze_native(folder, {"warmup_draws": 0, "draws": 1})
            self.assertEqual(result["stages"]["cpu_work_including_ffi_ms"]["ms"]["p95"], 8)

    def test_gpu_samples_keep_submission_frame_id_across_delayed_callbacks(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            # Warm GPU sample completes after a measured sample, and a second
            # warm frame has no GPU sample. Sample-count slicing would be wrong.
            (folder / "native.csv").write_text("gpu_pass_ms,2,3\ngpu_pass_ms,90,1\n", encoding="utf-8")
            (folder / "calls.csv").write_text("managed_draw_ms\n14\n", encoding="utf-8")
            result = evaluation.analyze_native(folder, {"warmup_draws": 2, "draws": 1})
            self.assertEqual(result["stages"]["gpu_pass_ms"]["ms"]["p95"], 2)

    def test_slow_common_workload_is_informational(self):
        result = {"columns": 120, "shape": "prose", "mode": "scroll"}
        evidence = {"result": result, "cpu_observation": "observed", "p95_ms": 100, "actual_present": {"status": "unverified"}}
        self.assertTrue(evaluation.decision([evidence]).startswith("informational"))

    def test_pressure_cpu_budget_is_not_a_common_workload_veto(self):
        result = {"columns": 400, "shape": "worstCase", "mode": "scroll"}
        evidence = {"result": result, "cpu_observation": "observed", "p95_ms": 100, "actual_present": {"status": "observed", "over_33_3_fraction": .5}}
        self.assertTrue(evaluation.decision([evidence]).startswith("informational"))

    def test_swapchain_readback_detects_missing_final_grid_row(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            result = {"columns": 3, "rows": 2, "physical_surface": {"width": 6, "height": 4}}
            for complete in (True, False):
                pixels = bytearray([18, 20, 26] * 24)
                for y in ([0, 2] if complete else [0]):
                    offset = (y * 6 + 4) * 3
                    pixels[offset:offset + 3] = bytes([240, 240, 240])
                (folder / "snapshot.ppm").write_bytes(b"P6\n6 4\n255\n" + pixels)
                self.assertEqual(evaluation.analyze_snapshot(folder, result)["status"], "pass" if complete else "fail")

    def test_pressure_correctness_failure_is_a_hard_failure(self):
        evidence = {"grid_boundary": {"status": "fail"}}
        self.assertTrue(evaluation.decision([evidence]).startswith("issues found"))


if __name__ == "__main__":
    unittest.main()
