# Commit and CI gates

Install once per clone with `python scripts/install-hooks.py`. The installer
records the interpreter in local Git configuration and enables `.githooks`.
The pinned YAML parser is installed into ignored `.check-deps`, rather than
changing the global Python environment. CI installs the same requirements.
`git commit` then runs `scripts/check.py --staged`; a missing tool or any failed
command blocks the commit. The hook does not fix files, retry failures or stash
your work. Stage all source changes first: partial staging and untracked files
are rejected, so the compiled source matches the index. Ignored build outputs
are allowed. The staged tree hash and index are checked again after validation;
changes staged during a long test run invalidate the result.

Run `python scripts/check.py` manually to validate the working tree. This can
take several minutes because it runs builds, tests and portable publishing.
The `--common-only`, `--windows-only` and `--apple-only` switches are CI job
entry points; normal commits run the full checks available on their host.

| Previous failure | Gate that catches recurrence |
| --- | --- |
| Rust formatting and lint errors | `cargo fmt --check`; workspace/all-targets Clippy with warnings denied |
| Linux-only local-shell initializer mismatch | Full workspace/all-targets build and tests on Linux CI |
| Missing Linux CJK fonts | Fontconfig language check before glyph shaping tests; CI installs fonts |
| Swift modifier Hashable and missing frame mouse argument | All six Swift package test builds on macOS |
| CRLF paste incorrectly treated as one Character | Existing Swift paste regression; Windows paste tests |
| Asynchronous file close checked after a fixed sleep | Files tests plus two extra executions of the close regression |
| PTY foreground/background cleanup and padded ps commands | App tests plus two extra ShellActivity executions |
| Broken directory/project references | XML input validation and real Windows build |
| Release packaging adds loose files | Real Release publish; exactly one EXE required |
| Hook returns success after a failed check | Negative controls including a real commit in a disposable Git repository |
| Test compiled by Xcode 27.1 here, "unable to type-check in reasonable time" on CI's Xcode 26.6 | `.xcode-version`: CI selects it on the `xcode-27` image; the Apple gate refuses any other Xcode |
| Lint on CI's newer `stable` Rust, absent from this machine's | `rust-toolchain.toml` names an exact version; CI runs `rustup toolchain install` from it |
| App resolved a sibling `../nerve` checkout that CI does not have | Apple gate builds with `TETHER_HERMETIC=1`; the manifest links Nerve only outside it |
| The hook's iOS link used the macOS SDK: `/usr/bin/git` exports `SDKROOT` to the hooks it runs | The gate drops an inherited `SDKROOT` before building; each target finds its own SDK |
| Every failure surfaced after merge, then again each night on the same commit | CI runs on pushes to `dev` as well as `master` |
| App and Files test processes exited 0 mid-run — no summary, a failure already printed — and the gate passed them | The gate judges each `swift test` by its report: any `✘`, or a run that never prints its summary, blocks. UI suites declare `.appKitEventLoop` |

Windows commits run common source/boundary checks, Rust format, Clippy, full
build/tests, native Debug/Release builds, WinUI build, four application regression
executables, both .NET test suites, and single-file publishing. They require
Rust, .NET 10, PowerShell 7 and the pinned `uniffi-bindgen-cs` generator used by
CI. Generated bindings are compared in a temporary directory without rewriting
the index or source. PowerShell syntax is parsed before building. Warnings fail
the WinUI build and release publish.

macOS commits run common checks, build the Apple XCFramework (device and
simulator included), and execute all Swift suites and the additional scheduling
runs. They require the appropriate Xcode SDK and Rust Apple targets.
The Files browser UI suites share one serialized parent because windows,
clipboard contents and the plugin dialog gateway are process-wide state.
The Apple gate repeats this entire UI group twice after the full package run;
an initial failure still blocks immediately. The installer regression invokes
the real installer in a disposable repository and verifies that a failing
checker prevents an actual commit.

Hook files alone do not enable a hook. Verify installation with
`git config --show-origin --get core.hooksPath` (expected `.githooks`) and
`git config --get tether.python` (expected the installed Python interpreter).
Rerun the installer if either setting is absent; Git does not transfer local
hook configuration when cloning a repository.

Linux commits run common checks and all fuzz targets for 60 seconds each,
including replay of stored regressions. They require CJK fonts, nightly Rust,
and cargo-fuzz. The scheduled CI fuzz run retains its longer 600-second budget.

A local pass counts only on CI's compilers and inputs. Both compilers are
pinned in the repository: `rust-toolchain.toml` (cargo obeys it here and on
CI) and `.xcode-version` (CI selects it; the Apple gate checks the selected
Xcode against it). To move to a new compiler, change the file; CI moves with
it. The gate compares the version only: the `xcode-27` image's 27.2 is a
release candidate (build 27B48) where this Mac has the release (27B52), until
the image catches up. The Apple gate builds every Swift package with `TETHER_HERMETIC=1`, which
leaves out anything checked out beside this repository — Nerve's native
panel, today — so it compiles what CI compiles. Builds outside the gate still
link Nerve when `../nerve` exists (`TETHER_NERVE`).

A `swift test` process idles in the run loop of Swift's async `main` and exits
0 when that run loop returns. Once a test pulls an AppKit event — a close
button's `performClick:`, a control's mouse tracking — HIToolbox wakes the
main thread for every later window-server event by stopping the main run
loop. With nothing but `main` there to receive it, the run ended early with
status 0, depending on whether a mouse moved. A suite that touches windows or
events declares `.appKitEventLoop` (`TetherTestSupport`), which runs
`NSApp.run()` for the process before its tests start;
`EventLoopTests` queues those stops on purpose. The gate no longer takes a
status of 0 on trust: a `✘` or a missing summary blocks.

The CI workflows use these same entry points on Windows, Linux and macOS.
The common checks include renderer-evidence parser regressions. Windows checks
also lint the opt-in render-diagnostics feature and build the HWND evaluation
harness; these compile/fixture checks do not run GPU benchmarks. Layout timing tests are
manual and ignored by default. Hardware performance is informational and never
a CI gate. See
[renderer evaluation](renderer-evaluation.md) for those separate measurements.
Windows cannot compile Apple SDK code, and macOS cannot build WinUI. A local
pass therefore is not a cross-platform pass. Retain all three CI jobs as required
merge checks; hooks are clone-local and Git permits bypassing them. No finite
test suite can guarantee that every future bug or timing failure is caught.

The previous failures were audited against Actions runs `37377445785`,
`37377743691`, `37378205043`, `37379991882`, `37485933247`, `37487016190`,
`37497642545`, and `37499894605`; final pre-change runs `37502306496` and
`37502306762` passed. The checks preserve the assertions rather than skipping
the tests that failed.
