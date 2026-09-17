# 0002 — What a consumer needs installed to build Tether

Status: accepted · 2026-09-17 · Phase 0 gate

## Context

Choosing `russh` brought `aws-lc-rs` with it, and `aws-lc-rs` compiles C and
assembly through `aws-lc-sys`. The previous Swift-native design had just been
abandoned partly to escape a native build story, so the obvious risk was
trading 240,000 lines of vendored C for a CMake dependency in every
contributor's and every CI job's path.

The specification makes this a gate rather than an assumption (§13): building
for Apple targets from cargo alone, with no CMake in a consumer's path, must be
demonstrated.

## What was measured

All three Apple targets build the full workspace:

| Target | Result |
|---|---|
| `aarch64-apple-darwin` | builds |
| `aarch64-apple-ios` | builds |
| `aarch64-apple-ios-sim` | builds |

`aws-lc-rs 1.18.1` → `aws-lc-sys 0.45.0` is genuinely in the iOS dependency
graph, with object files under `target/aarch64-apple-ios/`, so the C and
assembly really are compiled rather than skipped by feature resolution.

The decisive test removed **every** directory containing a `cmake` binary from
`PATH` — this machine had two, one in `~/.local/bin` and one in
`/opt/homebrew/bin`, and the first attempt at this test silently used the
second — then rebuilt from clean. `aws-lc-sys` compiled in 12 seconds without
CMake, taking its prebuilt/`cc` path.

## Decision

The toolchain contract for building Tether is:

- a Rust toolchain, with `aarch64-apple-ios` and `aarch64-apple-ios-sim` added
  (they are not installed by default);
- a C compiler, which Xcode Command Line Tools provide as `/usr/bin/cc`.

Nothing else. No CMake, no Ninja, no code generation, no network beyond
`cargo fetch`.

## Consequences

- The gate that could have forced a retreat to a different crypto backend is
  closed. `aws-lc-rs` stays the default; `ring` remains available as a russh
  feature if that ever changes.
- CI needs only a Rust toolchain and the Xcode CLT image.
- Worth re-testing whenever `aws-lc-sys` is upgraded: its build strategy is a
  property of that crate, not a promise to us. A regression would show up as
  CMake suddenly being required, so CI should build with a PATH that has no
  CMake on it, and keep the gate honest.
