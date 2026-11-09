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

spec = importlib.util.spec_from_file_location("bindgen", ROOT / "scripts/ensure-bindgen.py")
bindgen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bindgen)


class BindgenTests(unittest.TestCase):
    def probe(self, version):
        return subprocess.CompletedProcess([], 0, f"uniffi-bindgen {version}\n", "")

    def test_correct_version_skips_cargo_on_both_platforms(self):
        for platform, executable in (("darwin", "/tools/uniffi-bindgen-cs"),
                                     ("win32", r"C:\tools\uniffi-bindgen-cs.exe")):
            with self.subTest(platform=platform), patch.object(bindgen.sys, "platform", platform), \
                    patch.object(bindgen.shutil, "which", return_value=executable) as which, \
                    patch.object(bindgen.subprocess, "run", return_value=self.probe(bindgen.VERSION)) as run:
                bindgen.ensure_bindgen()
                which.assert_called_once_with("uniffi-bindgen-cs.exe" if platform == "win32" else "uniffi-bindgen-cs")
                run.assert_called_once_with([executable, "--version"], check=True, capture_output=True, text=True)

    def test_missing_installs_without_force_and_wrong_version_replaces_on_both_platforms(self):
        for platform, executable in (("darwin", "/tools/uniffi-bindgen-cs"),
                                     ("win32", r"C:\tools\uniffi-bindgen-cs.exe")):
            for version in (None, "0.10.0+v0.30.0", "0.11.0+v0.30.0"):
                missing = version is None
                with self.subTest(platform=platform, version=version), \
                        patch.object(bindgen.sys, "platform", platform), \
                        patch.object(bindgen.shutil, "which", side_effect=[None if missing else executable, executable]), \
                        patch.object(bindgen.subprocess, "run") as run:
                    installed = subprocess.CompletedProcess([], 0)
                    run.side_effect = ([installed] if missing else [self.probe(version), installed]) + [self.probe(bindgen.VERSION)]
                    bindgen.ensure_bindgen()
                    commands = [call.args[0] for call in run.call_args_list]
                    install = ["cargo", "install", "--locked", "uniffi-bindgen-cs", "--git",
                               "https://github.com/NordSecurity/uniffi-bindgen-cs", "--tag", "v0.11.0+v0.31.0"]
                    if not missing:
                        install.append("--force")
                    self.assertEqual(commands, ([] if missing else [[executable, "--version"]]) +
                                     [install, [executable, "--version"]])
                    self.assertEqual(run.call_args_list[-2].kwargs, {"check": True})

    def test_unrecognized_output_fails_without_installing(self):
        for output in ("", "uniffi-bindgen v0.11.0+v0.31.0\n", "uniffi-bindgen-cs 0.11.0+v0.31.0\n",
                       "other-tool 0.11.0+v0.31.0\n", "uniffi-bindgen 0.11.0+v0.31.0\nextra\n"):
            with self.subTest(output=output), patch.object(bindgen.shutil, "which", return_value="bindgen"), \
                    patch.object(bindgen.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")) as run:
                with self.assertRaisesRegex(RuntimeError, "Cannot identify"):
                    bindgen.ensure_bindgen()
                run.assert_called_once()

    def test_failed_probe_fails_without_installing(self):
        for error in (subprocess.CalledProcessError(2, ["bindgen", "--version"], stderr="probe failed"),
                      PermissionError("not executable"), FileNotFoundError("disappeared")):
            with self.subTest(error=error), patch.object(bindgen.shutil, "which", return_value="bindgen"), \
                    patch.object(bindgen.subprocess, "run", side_effect=error) as run:
                with self.assertRaises(type(error)):
                    bindgen.ensure_bindgen()
                run.assert_called_once()

    def test_install_failure_propagates_exit_status(self):
        for version in (None, "0.10.0+v0.30.0"):
            with self.subTest(version=version), patch.object(bindgen, "installed_version", return_value=version) as probe, \
                    patch.object(bindgen.subprocess, "run", side_effect=subprocess.CalledProcessError(17, ["cargo", "install"])) as run, \
                    patch.object(bindgen.sys, "stderr"):
                self.assertEqual(bindgen.main(), 17)
                run.assert_called_once()
                probe.assert_called_once()

    def test_install_must_leave_the_expected_version_on_path(self):
        for actual in (None, "0.10.0+v0.30.0"):
            with self.subTest(actual=actual), patch.object(bindgen, "installed_version", side_effect=[None, actual]), \
                    patch.object(bindgen.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "after installation"):
                    bindgen.ensure_bindgen()
                run.assert_called_once()



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
        with patch.object(gate.sys, "platform", "linux"), patch.object(gate, "source_checks"), patch.object(gate, "dependency_boundaries"), patch.object(gate, "run", side_effect=command):
            gate.common()

    def test_missing_cjk_font_blocks(self):
        with patch.object(gate.sys, "platform", "linux"), patch.object(gate, "source_checks"), patch.object(gate, "dependency_boundaries"), patch.object(gate, "run", return_value="en|fr"):
            with self.assertRaisesRegex(RuntimeError, "fonts-noto-cjk"):
                gate.common()

    def test_chrome_feature_has_to_reach_gpui_and_nothing_below_it(self):
        def tree(featured):
            def command(*args, **kwargs):
                return featured if "--features" in args else "plain"
            return command
        with patch.object(gate, "run", side_effect=tree("gpui v0.2.2 (https://github.com/zed-industries/zed?tag=v1.27.0)")):
            gate.dependency_boundaries()
        with patch.object(gate, "run", side_effect=tree("nothing")):
            with self.assertRaisesRegex(RuntimeError, "does not reach"):
                gate.dependency_boundaries()
        with patch.object(gate, "run", side_effect=tree("gpui v0.2.2\nwgpu v30")):
            with self.assertRaisesRegex(RuntimeError, "reaches wgpu"):
                gate.dependency_boundaries()
        with patch.object(gate, "run", side_effect=tree("gpui v0.2.2\ngpui_macos v0.1.0")):
            with self.assertRaisesRegex(RuntimeError, "reaches gpui_macos"):
                gate.dependency_boundaries()

    def test_a_layer_reaching_a_forbidden_backend_blocks(self):
        def command(*args, **kwargs):
            if "--features" in args:
                return "gpui v0.2.2"
            return "russh v0.63" if "tether-local" in args else ""
        with patch.object(gate, "run", side_effect=command):
            with self.assertRaisesRegex(RuntimeError, "tether-local reaches forbidden backend russh"):
                gate.dependency_boundaries()

    def test_gpui_moves_both_lines_to_one_stable_tag(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("bump", Path(__file__).with_name("bump-gpui.py"))
        bump = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bump)
        manifest = (
            'gpui = { git = "https://github.com/zed-industries/zed", tag = "v1.27.0", default-features = false }\n'
            'gpui_platform = { git = "https://github.com/zed-industries/zed", tag = "v1.27.0" }\n'
        )
        self.assertEqual(bump.pinned(manifest), "v1.27.0")
        moved = bump.retagged(manifest, "v1.28.0")
        self.assertEqual(bump.pinned(moved), "v1.28.0")
        self.assertIn("default-features = false", moved)
        with self.assertRaises(RuntimeError):
            bump.retagged(manifest, "v1.28.0-pre")
        with self.assertRaises(RuntimeError):
            bump.pinned(manifest.replace('tag = "v1.27.0" }', 'tag = "v1.26.2" }'))
        self.assertGreater(bump.version("v1.28.0"), bump.version("v1.27.10"))

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
                    found = re.fullmatch(r"python3? scripts/check\.py --job ([\w-]+)", command)
                    if found:
                        checks.append(found.group(1))
                    elif command in ("python3 scripts/ensure-bindgen.py", "python scripts/ensure-bindgen.py"):
                        pass
                    else:
                        self.assertRegex(command, f"^{setup.pattern}", f"{path.name} {name} runs outside the gate")
                self.assertEqual(checks, [name], f"{path.name} {name}")
                seen.add(name)
        # CI is one job on master; every CI job is a gate job.
        self.assertLessEqual(seen, set(gate.JOBS), "a CI job is a gate job")
        self.assertEqual(seen, gate.CI_JOBS, "CI runs exactly CI_JOBS")

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
