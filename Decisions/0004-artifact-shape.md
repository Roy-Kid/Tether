# 0004 — A Swift consumer gets a prebuilt XCFramework and checked-in bindings

Status: accepted
Date: 2026-09-17
Phase: 0 (final gate)

## Context

Spec §21 sets a hard constraint: a consumer must not need Rust, CMake or a
network to build their app, and names three candidate shapes — XCFramework,
prebuilt binary target, build plugin.

The constraint decides most of it. A SwiftPM build plugin that shells out to
`cargo` requires every app developer to install a Rust toolchain, which is
exactly what §21 forbids; it also puts a multi-minute native build inside every
clean app build. It is out on the constraint, not on taste.

## Decision

Three targets, and a consumer sees only the third:

- **`TetherFFI`** — a `binaryTarget` XCFramework holding one static library per
  Apple slice (`macos-arm64`, `ios-arm64`, `ios-arm64-simulator`), built by
  `scripts/build-xcframework.sh`. 163MB, so it is a release asset, never a
  committed file.
- **`TetherFFIBindings`** — uniffi's generated Swift, **checked in**. Generating
  it at build time would need the Rust toolchain the constraint rules out, so
  it is a build output that lives in the repository; the script rewrites it and
  CI fails on a diff. Swift 5 language mode, per Decision 0003.
- **`Tether`** — the façade. Swift 6, and the only target in `products`.

The C module is named `TetherFFI` through `crates/tether-ffi/uniffi.toml`, and
its header and module map are generated alongside the bindings rather than
hand-written, so the module the bindings import and the module the XCFramework
exposes cannot drift apart.

## Consequences

- A fresh clone of *Tether* cannot `swift build` until
  `scripts/build-xcframework.sh` has run once. Tether's own developers need
  Rust; that is the audience the constraint does not cover.
- The first tagged release switches the binary target from `path:` to
  `url:` + `checksum:`. No URL is written here, because none exists yet.
- `scripts/verify-consumer-build.sh` is the enforcement. It removes every PATH
  entry containing `cargo`, `rustc` or `cmake` — filtering by content, since
  this machine has carried two CMake installs at once — then builds, tests, and
  type-checks a file that must *fail* to prove generated symbols do not leak
  through the façade.
- That last check carries its own control. A file that fails to compile proves
  nothing about encapsulation if the include path is broken, so the script also
  compiles the same file *with* the generated module imported and fails if that
  does not build. The first version of this check reported a leak that did not
  exist, because `-parse` accepts anything syntactically valid.

## Evidence

With `cargo`, `rustc` and `cmake` all unreachable: 7/7 package tests pass,
generated symbols are unreachable through `Tether`, and the control compiles.
