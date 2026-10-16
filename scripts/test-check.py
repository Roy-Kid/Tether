"""Negative controls for the commit gate, in disposable Git repositories."""
import importlib.util
import os
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

    def test_failed_checker_really_prevents_git_commit(self):
        (self.root / ".githooks").mkdir()
        hook = self.root / ".githooks/pre-commit"
        shutil.copyfile(ROOT / ".githooks/pre-commit", hook)
        hook.chmod(0o755)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/check.py").write_text("raise SystemExit(23)\n")
        self.git("config", "core.hooksPath", ".githooks")
        self.git("config", "tether.python", sys.executable)
        self.git("add", ".")
        result = self.git("-c", "user.name=Gate Test", "-c", "user.email=gate@example.invalid",
                          "-c", "commit.gpgsign=false", "commit", "-m", "must be blocked", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotEqual(self.git("rev-parse", "--verify", "HEAD", check=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
