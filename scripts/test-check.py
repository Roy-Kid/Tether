"""Negative controls for the commit gate, in disposable Git repositories."""
import importlib.util
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("gate", ROOT / "scripts/check.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


ship_spec = importlib.util.spec_from_file_location("ship", Path(__file__).with_name("ship.py"))
ship = importlib.util.module_from_spec(ship_spec)
ship_spec.loader.exec_module(ship)


class ShipTests(unittest.TestCase):
    """dev and master take only commits every workflow passed."""

    def push(self, remote_ref, sha="a" * 40, green=False):
        line = f"refs/heads/topic {sha} {remote_ref} {'0' * 40}"
        with patch.object(ship, "verdict", return_value=(green, [] if green else ["Windows"])) as verdict:
            return ship.pre_push([line]), verdict

    def test_an_untried_commit_cannot_reach_dev_or_master(self):
        for branch in ship.PROTECTED:
            code, _ = self.push(f"refs/heads/{branch}")
            self.assertEqual(code, 1, branch)

    def test_a_commit_every_workflow_passed_goes_through(self):
        code, _ = self.push("refs/heads/dev", green=True)
        self.assertEqual(code, 0)

    def test_staging_branches_and_deletions_are_not_asked(self):
        code, verdict = self.push("refs/heads/ci/abc")
        self.assertEqual(code, 0)
        code, _ = self.push("refs/heads/dev", sha="0" * 40)
        self.assertEqual(code, 0)
        verdict.assert_not_called()


class GateTests(unittest.TestCase):
    def setUp(self):
        # Hooks can export the parent's index/repository; fixtures must never use it.
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                                      "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX")}
        self.environment = patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.git("init", "--quiet")

    def tearDown(self):
        # Git objects are read-only on Windows.
        def writable(function, path, error):
            Path(path).chmod(0o700)
            function(path)
        shutil.rmtree(self.root, onerror=writable)
        self.temp.cleanup()
        self.environment.stop()

    def git(self, *args, check=True):
        return subprocess.run(["git", *args], cwd=self.root, check=check,
                              capture_output=True, text=True)

    def test_native_terminal_cannot_reintroduce_a_renderer(self):
        source = self.root / "app/Packages/TetherFrontend/Sources/TetherUI"
        source.mkdir(parents=True)
        path = source / "TerminalView.swift"
        for text in ("import MetalKit", "let pipeline = MTLRenderPipelineDescriptor()", "Canvas { context, size in }"):
            path.write_text(text)
            with self.assertRaises(RuntimeError):
                gate.renderer_boundaries(self.root)
        path.write_text("import QuartzCore\nlet layer = CAMetalLayer()")
        gate.renderer_boundaries(self.root)
        other = source / "WgpuTerminal.swift"
        other.write_text("Canvas { context, size in }\n")
        with self.assertRaises(RuntimeError):
            gate.renderer_boundaries(self.root)
        other.write_text("import QuartzCore\nlet layer = CAMetalLayer()\n")
        gate.renderer_boundaries(self.root)

    def test_cjk_preflight_uses_a_supported_language_tag(self):
        def command(*args, **kwargs):
            if args[0] == "fc-match":
                self.assertEqual(args[-1], ":lang=zh-cn")
                return "en|zh-cn|zh-tw"
            return ""
        with patch.object(gate.sys, "platform", "linux"), patch.object(gate, "source_checks"), patch.object(gate, "run", side_effect=command):
            gate.common()

    def test_missing_cjk_font_blocks(self):
        with patch.object(gate.sys, "platform", "linux"), patch.object(gate, "source_checks"), patch.object(gate, "run", return_value="en|fr"):
            with self.assertRaisesRegex(RuntimeError, "fonts-noto-cjk"):
                gate.common()

    def test_unstaged_content_blocks(self):
        path = self.root / "example.txt"
        path.write_text("staged\n")
        self.git("add", ".")
        path.write_text("unstaged\n")
        with patch.object(gate, "ROOT", self.root):
            with self.assertRaises(subprocess.CalledProcessError):
                gate.staged_clean()

    def test_new_untracked_content_blocks(self):
        (self.root / "example.txt").write_text("new\n")
        with patch.object(gate, "ROOT", self.root):
            with self.assertRaises(RuntimeError):
                gate.staged_clean()

    def test_staged_whitespace_blocks(self):
        (self.root / "example.txt").write_text("invalid  \n")
        self.git("add", ".")
        with patch.object(gate, "ROOT", self.root):
            with self.assertRaises(subprocess.CalledProcessError):
                gate.staged_clean()

    def test_clean_index_passes(self):
        (self.root / "example.txt").write_text("valid\n")
        self.git("add", ".")
        with patch.object(gate, "ROOT", self.root):
            gate.staged_clean()

    def test_failed_command_propagates(self):
        with patch.object(gate, "ROOT", self.root):
            with self.assertRaises(subprocess.CalledProcessError) as result:
                gate.run(sys.executable, "-c", "raise SystemExit(17)")
            self.assertEqual(result.exception.returncode, 17)

    def test_missing_tool_blocks(self):
        with patch.object(gate, "ROOT", self.root):
            with self.assertRaises(OSError):
                gate.run("tether-intentionally-missing-check-tool")

    def test_invalid_workflow_blocks(self):
        workflows = self.root / ".github/workflows"
        workflows.mkdir(parents=True)
        (workflows / "broken.yml").write_text("name: [not closed\n")
        with patch.object(gate, "ROOT", self.root):
            with self.assertRaisesRegex(RuntimeError, "Invalid workflow YAML"):
                gate.source_checks()

    def test_changed_index_has_different_validation_identity(self):
        path = self.root / "example.txt"
        path.write_text("before\n")
        self.git("add", ".")
        with patch.object(gate, "ROOT", self.root):
            before = gate.staged_clean()
            path.write_text("after\n")
            self.git("add", ".")
            self.assertNotEqual(before, gate.staged_clean())

    def apple_commands(self, xcode):
        """Runs the Apple gate with every command recorded, not executed."""
        calls = []

        def command(*args, **kwargs):
            calls.append((args, kwargs.get("env")))
            return f"Xcode {xcode}\nBuild version 27A9275\n" if args[:2] == ("xcodebuild", "-version") else ""
        (self.root / ".xcode-version").write_text("27.1\n")
        def tests(*args, env):
            calls.append((("swift", "test", *args), env))
        with patch.object(gate, "ROOT", self.root), patch.object(gate, "run", side_effect=command), \
                patch.object(gate, "swift_test", side_effect=tests), \
                patch.object(gate, "iphone_simulator", return_value="00000000-0000-0000-0000-000000000000"), \
                patch.object(gate, "boot_in_background"):
            gate.apple(build=False)
        return calls

    def test_every_ci_job_is_setup_and_one_gate_job(self):
        # What CI runs and what a commit runs drifted apart once: a phone test
        # lived only in a workflow. A job may set its machine up, and then
        # runs the gate's job of the same name, and nothing else.
        import yaml
        setup = re.compile(r"(rustup |python3? -m pip install |sudo apt-get |cargo (\+nightly )?install |version=\$\(cat \.xcode-version\))")
        workflows = Path(__file__).resolve().parent.parent / ".github/workflows"
        seen = set()
        for path in sorted(workflows.glob("*.yml")):
            for name, job in yaml.safe_load(path.read_text(encoding="utf-8"))["jobs"].items():
                checks = []
                for step in job["steps"]:
                    command = step.get("run", "").strip()
                    if not command:
                        continue
                    found = re.fullmatch(r"python3? scripts/check\.py --job (\w+)", command)
                    if found:
                        checks.append(found.group(1))
                    else:
                        self.assertRegex(command, f"^{setup.pattern}", f"{path.name} {name} runs outside the gate")
                self.assertEqual(checks, [name], f"{path.name} {name}")
                seen.add(name)
        self.assertEqual(seen, set(gate.JOBS), "every gate job runs in CI, and only those")

    def test_an_sdk_git_exported_to_the_hook_is_not_used(self):
        os.environ["SDKROOT"] = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
        gate.drop_inherited_sdk()
        self.assertNotIn("SDKROOT", os.environ)

    def test_another_xcode_blocks_before_anything_compiles(self):
        # CI's Xcode 26.6 failed to type-check a test Xcode 27.1 compiled.
        with self.assertRaisesRegex(RuntimeError, r"\.xcode-version"):
            self.apple_commands("26.6")

    def test_swift_builds_without_sibling_checkouts(self):
        # A sibling checkout resolved here and nowhere else.
        calls = self.apple_commands("27.1")
        builds = [env for args, env in calls if args[0] in ("swift", "xcodebuild") and "-version" not in args]
        self.assertTrue(builds)
        for env in builds:
            self.assertEqual((env or {}).get("TETHER_HERMETIC"), "1")

    def test_a_test_run_must_finish_and_pass(self):
        finished = '◇ Test "a" started.\n✔ Test "a" passed.\n✔ Test run with 1 test in 1 suite passed.\n'
        gate.require_test_report(finished)
        gate.require_test_report("\t Executed 3 tests, with 0 failures (0 unexpected)\n")
        # The process ended mid-run with status 0: 398 started, no summary.
        with self.assertRaisesRegex(RuntimeError, "ended before"):
            gate.require_test_report('◇ Test "a" started.\n✔ Test "a" passed.\n◇ Test "b" started.\n')
        # A failure is a failure whatever the status said.
        with self.assertRaisesRegex(RuntimeError, "failed"):
            gate.require_test_report(finished + '✘ Test "b" recorded an issue\n')
        with self.assertRaisesRegex(RuntimeError, "failed"):
            gate.require_test_report("\t Executed 3 tests, with 1 failure (0 unexpected)\n")

    def test_failed_checker_really_prevents_git_commit(self):
        (self.root / ".githooks").mkdir()
        hook = self.root / ".githooks/pre-commit"
        shutil.copyfile(ROOT / ".githooks/pre-commit", hook)
        shutil.copyfile(ROOT / ".githooks/pre-push", self.root / ".githooks/pre-push")
        (self.root / "scripts").mkdir()
        (self.root / "scripts/check.py").write_text(
            "from pathlib import Path\nPath('.git/checker-ran').touch()\nraise SystemExit(23)\n")
        # Exercise the real installer: manually setting the configuration here
        # used to leave hook installation itself completely untested.
        shutil.copyfile(ROOT / "scripts/install-hooks.py", self.root / "scripts/install-hooks.py")
        (self.root / "scripts/check-requirements.txt").write_text("")
        subprocess.run([sys.executable, str(self.root / "scripts/install-hooks.py")],
                       cwd=self.root, check=True, capture_output=True, text=True)
        self.assertEqual(self.git("config", "--get", "core.hooksPath").stdout.strip(), ".githooks")
        self.assertEqual(self.git("config", "--get", "tether.python").stdout.strip(), sys.executable)
        self.git("add", ".")
        result = self.git("-c", "user.name=Gate Test", "-c", "user.email=gate@example.invalid",
                          "-c", "commit.gpgsign=false", "commit", "-m", "must be blocked", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / ".git/checker-ran").exists(), result.stdout + result.stderr)
        self.assertNotEqual(self.git("rev-parse", "--verify", "HEAD", check=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
