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

Linux commits run common checks and all fuzz targets for 60 seconds each,
including replay of stored regressions. They require CJK fonts, nightly Rust,
and cargo-fuzz. The scheduled CI fuzz run retains its longer 600-second budget.

The CI workflows use these same entry points on Windows, Linux and macOS.
Windows cannot compile Apple SDK code, and macOS cannot build WinUI. A local
pass therefore is not a cross-platform pass. Retain all three CI jobs as required
merge checks; hooks are clone-local and Git permits bypassing them. No finite
test suite can guarantee that every future bug or timing failure is caught.

The previous failures were audited against Actions runs `37377445785`,
`37377743691`, `37378205043`, `37379991882`, `37485933247`, `37487016190`,
`37497642545`, and `37499894605`; final pre-change runs `37502306496` and
`37502306762` passed. The checks preserve the assertions rather than skipping
the tests that failed.
