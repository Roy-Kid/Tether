"""Shared CI/pre-commit gate. Checks fail closed; no automatic fixes or retries."""
import argparse
import ast
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / ".check-deps"))


def run(*command, capture=False, cwd=None):
    command = list(map(str, command))
    if command[0] == "dotnet" and sys.platform == "win32" and not shutil.which("dotnet"):
        command[0] = str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "dotnet/dotnet.exe")
    print("+ " + " ".join(map(str, command)), flush=True)
    return subprocess.run(command, cwd=cwd or ROOT, check=True,
                          text=True, encoding="utf-8", errors="replace",
                          stdout=subprocess.PIPE if capture else None).stdout


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def staged_clean():
    # Reject partial staging instead of testing code different from the index.
    run("git", "diff", "--exit-code", "--quiet")
    untracked = run("git", "ls-files", "--others", "--exclude-standard", capture=True)
    require(not untracked.strip(), "Stage new files before committing:\n" + untracked)
    run("git", "diff", "--cached", "--check")
    return run("git", "write-tree", capture=True).strip()


def source_checks():
    try:
        import yaml
    except ImportError as error:
        raise RuntimeError("Install check dependencies: python scripts/install-hooks.py") from error
    run("git", "diff", "--check")
    for path in (ROOT / ".github/workflows").glob("*.yml"):
        try:
            yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as error:
            raise RuntimeError(f"Invalid workflow YAML: {path}: {error}") from error
    print("Specification SHA256: " + hashlib.sha256(
        (ROOT / ".claude/notes/remote-platform-spec.md").read_bytes()).hexdigest(), flush=True)
    for path in (ROOT / "scripts").glob("*.py"):
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for path in ROOT.glob("tests/*/*.csproj"):
        for node in ET.parse(path).iter():
            include = node.get("Include", "")
            if node.tag in ("Compile", "ProjectReference") and "*" not in include:
                require((path.parent / include.replace("\\", "/")).exists(),
                        f"Missing project input: {path.relative_to(ROOT)}: {include}")
    for path in ROOT.glob("app-win/**/*.pubxml"):
        ET.parse(path)
    ET.parse(ROOT / "app-win/app.manifest")
    ET.parse(ROOT / "app-win/TetherApp.Windows.csproj")
    for path in (ROOT / "app/Sources").rglob("*.swift"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(r"tmux|FilesPlugin|FilesTab", line, re.I):
                require(bool(re.search(r"import (Tmux|Files)Plugin$|registry\.register\((Tmux|Files)Plugin\(\)\)", line)),
                        f"Plugin boundary violation: {path}:{number}")
    sources = [ROOT / "app/Sources", ROOT / "app/Packages/TetherFrontend/Sources",
               ROOT / "app/Packages/TetherPluginHost/Sources"]
    sources += list((ROOT / "app/Plugins").glob("*/Sources"))
    for base in sources:
        for path in base.rglob("*.swift"):
            if "TetherUI/DialogSurface" in path.as_posix():
                continue
            require(not re.search(r"\.alert\(|\.confirmationDialog\(|UIAlertController|NSAlert\b",
                                  path.read_text(encoding="utf-8")), f"Dialog boundary violation: {path}")


def common():
    run(sys.executable, "scripts/test-check.py")
    source_checks()
    if sys.platform.startswith("linux"):
        languages = run("fc-match", "--format=%{lang}", ":lang=zh-cn", capture=True)
        require("zh" in languages, "Install fonts-dejavu-core and fonts-noto-cjk before checking.")
    run("cargo", "fmt", "--all", "--check")
    run("cargo", "clippy", "--locked", "--workspace", "--all-targets", "--", "-D", "warnings")
    run("cargo", "build", "--locked", "--workspace", "--all-targets")
    run("cargo", "test", "--locked", "--workspace")
    for crate, backend in (("tether-terminal", "russh"), ("tether-local", "russh"),
                           ("tether-ssh", "portable-pty")):
        require(backend not in run("cargo", "tree", "--locked", "-p", crate, capture=True),
                f"{crate} reaches forbidden backend {backend}")


def stage_native(release=False):
    args = ["cargo", "build", "--locked", "-p", "tether-ffi", "--features", "render"]
    if release:
        args.append("--release")
    run(*args)
    target = Path(os.environ.get("CARGO_TARGET_DIR", str(ROOT / "target")))
    if not target.is_absolute():
        target = ROOT / target
    library = target / ("release" if release else "debug") / "tether_ffi.dll"
    destination = ROOT / "dotnet/Tether/runtimes/win-x64/native"
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(library, destination / library.name)
    return library


def verify_bindings(library):
    with tempfile.TemporaryDirectory(prefix="tether-binding-check-") as temporary:
        run("uniffi-bindgen-cs", "--library", library, "--out-dir", temporary)
        # Generator/formatter whitespace is irrelevant; API changes are not.
        run("git", "diff", "--no-index", "--ignore-all-space", "--exit-code",
            ROOT / "dotnet/Tether/Generated/tether_ffi.cs", Path(temporary) / "tether_ffi.cs")


def windows():
    run("pwsh", "-NoProfile", "-Command",
        "$ErrorActionPreference='Stop'; foreach($file in Get-ChildItem scripts -Filter *.ps1) { "
        "$tokens=$null; $problems=$null; "
        "[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$problems) | Out-Null; "
        "if($problems.Count) { throw ($problems | Out-String) } }")
    verify_bindings(stage_native())
    run("dotnet", "build", "app-win/TetherApp.Windows.csproj", "-c", "Debug",
        "-p:Platform=x64", "-warnaserror")
    for name in ("terminal-experience", "connection-errors", "windows-files", "windows-management"):
        run("dotnet", "run", "--project", "tests/" + name)
    for name in ("ssh-config", "plugins"):
        run("dotnet", "test", "tests/" + name, "-warnaserror")
    stage_native(release=True)
    run("pwsh", "-NoProfile", "-File", "scripts/publish-windows.ps1", "-SkipNativeBuild")


def apple(build=True):
    if build:
        run("bash", "scripts/build-xcframework.sh")
    for package in ("swift", "app/Packages/TetherFrontend", "app/Packages/TetherPluginHost",
                    "app/Plugins/Tmux", "app/Plugins/Files", "app"):
        run("swift", "test", "--package-path", package)
    run("xcodebuild", "-scheme", "TetherApp", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", ROOT / "artifacts/ios-check", "CODE_SIGNING_ALLOWED=NO", "build", cwd=ROOT / "app")
    # Previously flaky regressions must survive additional scheduling runs.
    for _ in range(2):
        run("swift", "test", "--package-path", "app/Plugins/Files", "--filter", "closeClosesTheSession")
        run("swift", "test", "--package-path", "app", "--filter", "ShellActivityTests")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--common-only", action="store_true")
    group.add_argument("--windows-only", action="store_true")
    group.add_argument("--apple-only", action="store_true")
    args = parser.parse_args()
    if args.staged:
        checked_tree = staged_clean()
    if args.windows_only:
        windows()
    elif args.apple_only:
        apple(build=False)
    else:
        common()
        if not args.common_only:
            if sys.platform == "win32":
                windows()
            elif sys.platform == "darwin":
                apple()
            else:
                run("bash", "scripts/fuzz-targets.sh", "--seconds", "60")
    if args.staged:
        require(staged_clean() == checked_tree, "The staged tree changed during validation; run the checks again.")
    print("PASS: all requested checks completed. Other platforms remain required CI gates.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, SyntaxError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        sys.exit(1)
