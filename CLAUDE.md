# CLAUDE.md

## What this repo is

Tether is a set of Rust components an application imports to embed a working
SSH terminal, with platform-native bindings and views on top. Two products live
here: **the SDK**, which is the primary product, and **the app**, a standalone
terminal client shipped on the App Store and the first consumer of that SDK.

The value is composition, boundaries and API — not engine internals. SSH,
cryptography, VT parsing and text shaping are composed from mature upstream
crates (`russh`, `aws-lc-rs`, `alacritty_terminal`, `wgpu`, `cosmic-text`).

The defining document is `.claude/notes/remote-platform-spec.md`, mirrored
byte-for-byte in `molab-apple`, an external consumer. The two copies must change
together. Read it before touching architecture.

## Where things live

- `Cargo.toml`, `crates/` — the SDK. Crates appear only when they have work;
  an empty crate for a future phase is a layer added "because it may be useful
  later", which the spec forbids (§22).
- `Decisions/` — ADRs. Anything expensive to reverse gets one (spec §25).
- `.claude/notes/` — the specification and durable project knowledge.

## Law (never violated)

- **Compose, do not rewrite.** Engines come from mature upstream crates judged
  on the spec's five criteria (§5). A boundary exists to keep a dependency's
  types out of our public surface, never to re-implement it.
- **The SDK does not know its consumers.** No consumer's name, identifier,
  storage path or wording appears in the components.
- **`tether-terminal` links no SSH symbol.** `cargo tree -p tether-terminal`
  is the test (spec §3, §8).
- **Backends are confined.** `russh` types stop inside `tether-ssh`;
  `alacritty_terminal` types stop inside `tether-terminal` (spec §8).
- **Headless first.** The core must connect, authenticate, run a shell and
  expose terminal state with no UI framework linked. An acceptance criterion,
  not an aspiration (spec §15).
- **No UI toolkit types in the frontend contract** (spec §14).
- **Errors are ours.** Backend error numbers are diagnostic context, never the
  public API (spec §18).
- **Keyboard-interactive is generic.** Never encode `keyboard-interactive ==
  OTP` (spec §10).
- **Conservative security defaults.** Strict host verification, no trust-all,
  no secret logging; remote data is untrusted input (spec §18).

## Working here

```bash
cargo build
cargo test
cargo tree -p tether-terminal    # must show no russh
```

iOS targets are not installed by default:
`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`.

## Status

Phase 0. The crates are scaffolding with real dependencies and real boundaries.
Next: the binding seam (async across FFI, interactive prompts upward,
cancellation both directions), `aws-lc-rs` building for Apple targets from
cargo alone, and the artifact shape a Swift consumer sees.
