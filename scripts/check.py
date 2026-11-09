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
import threading
import time
import queue
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / ".check-deps"))


def run(*command, capture=False, cwd=None, env=None):
    command = list(map(str, command))
    if command[0] == "dotnet" and sys.platform == "win32" and not shutil.which("dotnet"):
        command[0] = str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "dotnet/dotnet.exe")
    print("+ " + " ".join(map(str, command)), flush=True)
    if not capture:
        stream(command, cwd=cwd, env=env)
        return None
    return subprocess.run(command, cwd=cwd or ROOT, check=True, env=env,
                          text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE).stdout


# A command that prints nothing this long is stuck, not slow: two gates once
# sat for eighty minutes on each other's windows, and a CI simulator run for
# ninety, with no line printed.
SILENCE_MINUTES = 10


def stream(command: list[str], cwd=None, env=None) -> str:
    """Run `command`, shown as it runs; its output, or an error once it has
    failed or gone silent."""
    started = time.monotonic()
    lines = []
    with subprocess.Popen(command, cwd=cwd or ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, encoding="utf-8", errors="replace") as process:
        heard = queue.Queue()
        threading.Thread(target=lambda: [heard.put(line) for line in process.stdout] + [heard.put(None)],
                         daemon=True).start()
        while True:
            try:
                line = heard.get(timeout=SILENCE_MINUTES * 60)
            except queue.Empty:
                process.kill()
                raise RuntimeError(f"{' '.join(command)} printed nothing for {SILENCE_MINUTES} minutes.")
            if line is None:
                break
            print(line, end="", flush=True)
            lines.append(line)
    took(started)
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, command)
    return "".join(lines)


def took(started: float) -> None:
    """Where a slow gate spends its time, without a second run to find out."""
    seconds = time.monotonic() - started
    if seconds >= 5:
        print(f"  ({seconds:.0f}s)", flush=True)


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
    ui_boundaries(ROOT)


def ui_boundaries(root=ROOT):
    # Chrome paints no window and no platform service. `desktop/` owns both
    # (Decisions/0022), and there only `desktop/src/platform/` names an OS.
    forbidden = (
        "open_window",
        "gpui_platform",
        "NSPanel",
        "NSWindow",
        "CKContainer",
        "SecItem",
        "UIAlertController",
        "NSAlert",
    )
    for path in (root / "crates/tether-ui").rglob("*.rs"):
        source = path.read_text(encoding="utf-8")
        for word in forbidden:
            require(word not in source, f"UI boundary violation: {path}: {word}")
    # The host's workspace names no OS. What a platform alone has is one module.
    platform = root / "desktop/src/platform"
    for path in (root / "desktop/src").rglob("*.rs"):
        if platform in path.parents:
            continue
        source = path.read_text(encoding="utf-8")
        for word in ("objc2", "NSView", "NSWindow", "CAMetalLayer", "HWND", "windows::"):
            require(word not in source, f"platform API outside desktop/src/platform: {path}: {word}")


def common():
    run(sys.executable, "scripts/test-check.py")
    run(sys.executable, "scripts/test-render-evaluation.py")
    source_checks()
    if sys.platform.startswith("linux"):
        languages = run("fc-match", "--format=%{lang}", ":lang=zh-cn", capture=True)
        require("zh" in languages, "Install fonts-dejavu-core and fonts-noto-cjk before checking.")
    run("cargo", "fmt", "--all", "--check")
    # Clippy over every target compiles the whole workspace at once (what
    # once caught two calls to functions that no longer existed); the tests
    # build what they link. A separate full build added a minute and nothing.
    run("cargo", "clippy", "--locked", "--workspace", "--all-targets", "--", "-D", "warnings")
    run("cargo", "test", "--locked", "--workspace")
    dependency_boundaries()


def dependency_boundaries():
    # Default features. tether-ui's gpui feature stays off, so this compile
    # does not include the UI toolkit. The pairs fail if a layer reaches
    # into another: chrome into the renderer, the renderer into chrome.
    for crate, backend in (("tether-terminal", "russh"), ("tether-local", "russh"),
                           ("tether-ssh", "portable-pty"),
                           ("tether-ui", "wgpu"), ("tether-ui", "russh"),
                           ("tether-ui", "tether-render"), ("tether-ui", "tether-terminal"),
                           ("tether-render", "gpui"), ("tether-render", "tether-ui"),
                           ("tether-terminal", "gpui"), ("tether-terminal", "tether-ui"),
                           ("tether-ffi", "gpui"), ("tether-ffi", "tether-ui"),
                           ("tether-desktop", "xgpui")):
        require(backend not in run("cargo", "tree", "--locked", "-p", crate, capture=True),
                f"{crate} reaches forbidden backend {backend}")
    # The feature is not compiled here. The tree still has to stay in its layer:
    # GPUI for chrome, and not the terminal renderer or the window backend.
    featured = run("cargo", "tree", "--locked", "-p", "tether-ui", "--features", "gpui",
                   capture=True)
    require("xgpui" in featured, "tether-ui gpui feature does not reach its UI toolkit")
    for backend in ("wgpu", "russh", "tether-render", "tether-terminal", "gpui_platform",
                    "portable-pty"):
        require(backend not in featured, f"tether-ui gpui feature reaches {backend}")


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


def dotnet_tests(release=False, *flags):
    """The .NET suites, over the native library they load."""
    library = stage_native(release=release)
    for name in ("terminal-experience", "connection-errors", "windows-files", "windows-management"):
        run("dotnet", "run", "--project", "tests/" + name)
    for name in ("ssh-config", "plugins"):
        run("dotnet", "test", "tests/" + name, *flags)
    return library


def windows():
    run("pwsh", "-NoProfile", "-Command",
        "$ErrorActionPreference='Stop'; foreach($file in Get-ChildItem scripts -Filter *.ps1) { "
        "$tokens=$null; $problems=$null; "
        "[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$problems) | Out-Null; "
        "if($problems.Count) { throw ($problems | Out-String) } }")
    # One native build, the release one the portable package ships: the
    # bindings, the regressions and the publish all use it.
    verify_bindings(dotnet_tests(True, "-warnaserror"))
    run("cargo", "clippy", "--locked", "-p", "tether-ffi", "--features", "render-diagnostics",
        "--all-targets", "--", "-D", "warnings")
    run("dotnet", "build", "tests/render-evaluation", "-c", "Release", "-warnaserror")
    # The app compiles here, in Release with warnings as errors, and must
    # still publish as one executable.
    run("pwsh", "-NoProfile", "-File", "scripts/publish-windows.ps1", "-SkipNativeBuild")


def windows_tests():
    """What a push waits for: the tests only Windows can run. No lint, and
    nothing the gate on a Mac already checked; `windows` is the whole job."""
    run("cargo", "test", "--locked", "--workspace")
    dotnet_tests()


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
    """`swift test`, judged on what it reported.

    Indexing and full DWARF are for a debugger. The gate builds seven
    packages and never reads either, and they are most of that time.
    """
    command = ["swift", "test", "--disable-index-store", "-debug-info-format", "none", *args]
    print("+ " + " ".join(command), flush=True)
    require_test_report(stream(command, env=env))


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
    # A simulator takes minutes to boot and nothing waits on it until the
    # phone's tests: it boots while everything else builds.
    simulator = iphone_simulator()
    boot_in_background(simulator)
    # What CI has: this repository and nothing beside it. A sibling checkout
    # the app's manifest can reach otherwise resolves here and nowhere else.
    hermetic = {**os.environ, "TETHER_HERMETIC": "1"}
    if build:
        # The Mac and the simulator are where the checks run; a device slice
        # is a third build that nothing here would load. Debug, because a
        # release build with LTO was most of the job and tests no other code.
        run("bash", "scripts/build-xcframework.sh",
            env={**hermetic, "TETHER_XCFRAMEWORK_TARGETS": "aarch64-apple-darwin aarch64-apple-ios-sim",
                 "TETHER_XCFRAMEWORK_PROFILE": "debug"})
    # The C# bindings come from the library's metadata, the same on every
    # platform: a Rust change made here shows up here, not first on Windows.
    verify_bindings(ROOT / "target/aarch64-apple-darwin/debug/libtether_ffi.dylib")
    for package in ("swift", "app/Packages/TetherFrontend", "app/Packages/TetherPluginHost",
                    "app/Plugins/Tmux", "app/Plugins/Files", "app/Plugins/Ports", "app"):
        swift_test("--package-path", package, env=hermetic)
    run("xcodebuild", "-scheme", "TetherApp", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", ROOT / "artifacts/ios-check", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64",
        "ONLY_ACTIVE_ARCH=YES", "COMPILER_INDEX_STORE_ENABLE=NO", "DEBUG_INFORMATION_FORMAT=dwarf",
        "build",
        cwd=ROOT / "app", env=hermetic)
    # The phone's own frontend tests are `#if os(iOS)`: `swift test` on a Mac
    # compiles them out, so they run on a simulator or nowhere.
    run("xcodebuild", "test", "-scheme", "TetherFrontend-Package",
        "-destination", f"platform=iOS Simulator,id={simulator}",
        "-derivedDataPath", ROOT / "artifacts/ios-check", "CODE_SIGNING_ALLOWED=NO",
        "COMPILER_INDEX_STORE_ENABLE=NO",
        cwd=ROOT / "app/Packages/TetherFrontend", env=hermetic)


def boot_in_background(simulator: str) -> None:
    """Already booted is fine; a failure here shows up in the test that
    needed it."""
    subprocess.Popen(["xcrun", "simctl", "boot", simulator], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def iphone_simulator():
    """The first available iPhone, as CI picks one."""
    listing = run("xcrun", "simctl", "list", "devices", "available", capture=True)
    found = re.search(r"^\s+iPhone[^\n]*\(([0-9A-F-]{36})\)", listing, re.M)
    require(found is not None, "No iPhone simulator is available.")
    return found.group(1)


def fuzz():
    """Every recorded crash replayed, then a short pass per target. The night's
    long run sets TETHER_FUZZ_SECONDS; finding something new is its job."""
    seconds = os.environ.get("TETHER_FUZZ_SECONDS", "10")
    run("bash", "scripts/fuzz-targets.sh", "--seconds", seconds)


# A CI job is one of these, and runs nothing else (test-check.py holds the
# workflows to it). A commit runs the job that is one workspace build.
# `apple` compiles seven Swift packages and an iOS slice, and `fuzz` brings
# up nightly; both run when the branch is pushed, not before the commit.
JOBS = {
    "linux": lambda: common(),
    "apple": lambda: apple(),
    "windows": lambda: (common(), windows()),
    "windows-tests": windows_tests,
    "fuzz": lambda: fuzz(),
}
HOST_JOBS = {"darwin": ("linux",), "win32": ("windows",)}


def drop_inherited_sdk():
    """Apple's /usr/bin/git exports SDKROOT, the Command Line Tools' macOS SDK,
    to the hooks it runs. One SDKROOT names one platform and the XCFramework is
    built for several, so its iOS slices linked against macOS. Each build finds
    its own SDK, as it does outside the hook and on CI."""
    os.environ.pop("SDKROOT", None)


def one_at_a_time():
    """Two gates in one checkout share its build directories, and two app
    test runs share the window server; a second one waits for nothing."""
    path = ROOT / "target" / "check.lock"
    path.parent.mkdir(exist_ok=True)
    lock = open(path, "a+")
    try:
        if sys.platform == "win32":
            import msvcrt
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise RuntimeError("Another check is already running in this checkout.")
    return lock


def main():
    drop_inherited_sdk()
    held = one_at_a_time()  # released when the process ends
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true")
    parser.add_argument("--job", choices=sorted(JOBS), action="append",
                        help="the CI job to run; repeatable. Default: every job this host can run")
    args = parser.parse_args()
    if args.staged:
        checked_tree = staged_clean()
    jobs = args.job or HOST_JOBS.get(sys.platform, ("linux",))
    for job in jobs:
        print(f"== job {job}", flush=True)
        JOBS[job]()
    if args.staged:
        require(staged_clean() == checked_tree, "The staged tree changed during validation; run the checks again.")
    others = sorted(set(JOBS) - set(jobs))
    print("PASS: " + ", ".join(jobs) + (". Left to CI: " + ", ".join(others) if others else "") + ".")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, SyntaxError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        sys.exit(1)
