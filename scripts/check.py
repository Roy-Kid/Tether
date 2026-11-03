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


def run(*command, capture=False, cwd=None, env=None):
    command = list(map(str, command))
    if command[0] == "dotnet" and sys.platform == "win32" and not shutil.which("dotnet"):
        command[0] = str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "dotnet/dotnet.exe")
    print("+ " + " ".join(map(str, command)), flush=True)
    return subprocess.run(command, cwd=cwd or ROOT, check=True, env=env,
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


def renderer_boundaries(root=ROOT):
    # Native hosts may attach a layer/window, never implement a second terminal
    # atlas, shader or grid painter. Keep this executable beside other seams.
    swift_sources = [root / "app/Sources", root / "swift/Sources/Tether"]
    swift_sources += list((root / "app/Packages").glob("*/Sources"))
    swift_sources += list((root / "app/Plugins").glob("*/Sources"))
    bases = [(base, "swift") for base in swift_sources]
    bases += [(root / "app-win", "cs"), (root / "dotnet/Tether", "cs")]
    for base, suffix in bases:
        for path in base.rglob("*." + suffix):
            if "Generated" in path.parts:
                continue
            source = path.read_text(encoding="utf-8")
            forbidden = r"\b(?:GlyphAtlas|RowPictureCache|MTLRenderPipelineDescriptor|MTLRenderCommandEncoder|MTLCommandQueue|CTLineDraw|CreateShaderModule|CreateRenderPipeline|CreateGraphicsPipelineState)\b"
            require(not re.search(forbidden, source), f"Renderer boundary violation: {path}")
            if suffix == "swift":
                require(not re.search(r"^\s*import Metal(?:Kit)?\s*$", source, re.M),
                        f"Renderer boundary violation: {path}")
                require(not re.search(r"\bCanvas\s*[{(]", source), f"Independent terminal painter: {path}")


def source_checks():
    renderer_boundaries(ROOT)
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
            if re.search(r"tmux|FilesPlugin|FilesTab|PortsPlugin|PortsTab", line, re.I):
                require(bool(re.search(r"import (Tmux|Files|Ports)Plugin$|registry\.register\((Tmux|Files|Ports)Plugin\(\)\)", line)),
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
    run(sys.executable, "scripts/test-render-evaluation.py")
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
    run("cargo", "clippy", "--locked", "-p", "tether-ffi", "--features", "render-diagnostics",
        "--all-targets", "--", "-D", "warnings")
    run("dotnet", "build", "tests/render-evaluation", "-c", "Release", "-warnaserror")
    run("dotnet", "run", "--project", "tests/render-evaluation", "-c", "Release", "--no-build", "--", "--validate-fixtures")
    run("dotnet", "build", "app-win/TetherApp.Windows.csproj", "-c", "Debug",
        "-p:Platform=x64", "-warnaserror")
    for name in ("terminal-experience", "connection-errors", "windows-files", "windows-management"):
        run("dotnet", "run", "--project", "tests/" + name)
    for name in ("ssh-config", "plugins"):
        run("dotnet", "test", "tests/" + name, "-warnaserror")
    stage_native(release=True)
    run("pwsh", "-NoProfile", "-File", "scripts/publish-windows.ps1", "-SkipNativeBuild")


def require_test_report(output: str) -> None:
    """The exit status alone is not the verdict. The app's test process has
    ended mid-run with status 0 — 398 tests started, no summary, a failure
    already printed — and the gate passed it."""
    failed = re.search(r"^\s*✘ |Executed \d+ tests?, with [1-9]\d* failures?", output, re.M)
    require(not failed, "A test failed: " + (failed.group(0).strip() if failed else ""))
    started = "◇ Test " in output
    summarized = re.search(r"^\s*✔ Test run with \d+ tests?", output, re.M)
    require(not started or summarized, "The test run ended before reporting; its status cannot be trusted.")
    require(started or "Executed " in output, "No test ran.")


def swift_test(*args: str, env: dict) -> None:
    """`swift test`, shown as it runs, and judged on what it reported."""
    command = ["swift", "test", *args]
    print("+ " + " ".join(command), flush=True)
    lines = []
    with subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, encoding="utf-8", errors="replace") as process:
        for line in process.stdout:
            print(line, end="", flush=True)
            lines.append(line)
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, command)
    require_test_report("".join(lines))


def require_pinned_xcode():
    """A pass on another compiler proves nothing: CI's Xcode 26.6 could not
    type-check a test that Xcode 27.1 compiled. CI selects the same file."""
    pinned = (ROOT / ".xcode-version").read_text(encoding="utf-8").strip()
    selected = run("xcodebuild", "-version", capture=True).splitlines()[0].removeprefix("Xcode ").strip()
    require(selected == pinned,
            f"Xcode {selected} is selected; CI builds with Xcode {pinned} (.xcode-version). "
            "Select that Xcode, or change .xcode-version so CI moves with you.")


def apple(build=True):
    require_pinned_xcode()
    # What CI has: this repository and nothing beside it. A sibling checkout
    # the app's manifest can reach otherwise resolves here and nowhere else.
    hermetic = {**os.environ, "TETHER_HERMETIC": "1"}
    if build:
        run("bash", "scripts/build-xcframework.sh")
    for package in ("swift", "app/Packages/TetherFrontend", "app/Packages/TetherPluginHost",
                    "app/Plugins/Tmux", "app/Plugins/Files", "app/Plugins/Ports", "app"):
        swift_test("--package-path", package, env=hermetic)
    run("xcodebuild", "-scheme", "TetherApp", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", ROOT / "artifacts/ios-check", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "build",
        cwd=ROOT / "app", env=hermetic)
    # Previously flaky regressions must survive additional scheduling runs.
    for _ in range(2):
        swift_test("--package-path", "app/Plugins/Files", "--filter", "BrowserUITests", env=hermetic)
        swift_test("--package-path", "app/Plugins/Files", "--filter", "closeClosesTheSession", env=hermetic)
        swift_test("--package-path", "app", "--filter", "ShellActivityTests", env=hermetic)


def drop_inherited_sdk():
    """Apple's /usr/bin/git exports SDKROOT, the Command Line Tools' macOS SDK,
    to the hooks it runs. One SDKROOT names one platform and the XCFramework is
    built for three, so its iOS slices linked against macOS. Each build finds
    its own SDK, as it does outside the hook and on CI."""
    os.environ.pop("SDKROOT", None)


def main():
    drop_inherited_sdk()
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
