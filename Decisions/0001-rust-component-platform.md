# 0001 — Tether composes mature Rust components rather than writing engines

Status: accepted · 2026-09-17

## Context

Tether was first specified as a Swift-native SDK: Swift owning the public API,
the terminal engine, the session model and the concurrency, with libssh2 and
Mbed TLS vendored underneath as the only native code. That design was built far
enough to prove it works — a clean checkout compiled libssh2 against Mbed TLS
in under five seconds from vendored source, and Swift reached it through a
backend seam.

Building it surfaced two facts worth keeping, because both cost real time:

- **libssh2's Mbed TLS 4 port is incomplete.** Its crypto backend is ported and
  guards correctly on `MBEDTLS_VERSION_NUMBER`, but `src/kex.c` still reaches
  for the bignum API in 60 unconditional places through a mapping with no 4.x
  branch — and Mbed TLS 4 moved bignum to `mbedtls/private/`. Building on 4.x
  would mean depending on a deliberately private API in the path that
  negotiates every connection's keys. Mbed TLS 3.6 LTS was the latest version
  that actually worked.
- **SwiftPM does not initialise submodules of dependency packages**, and
  `swift build` must work offline, so vendoring source into the repository was
  the only distributable option — roughly 240,000 lines of C.

Three things then changed the premise.

**A non-Apple frontend became plausible.** The original answer was "Apple
only". Once a Tauri frontend is on the table, a Swift core is the wrong
substrate: Tauri's backend *is* Rust, and a Swift core would have to be
cross-compiled for Windows and bound to Rust or JavaScript — a path almost
nobody walks.

**The Swift-native stack was already fragile.** The reason it used libssh2 at
all is that SwiftNIO SSH has no keyboard-interactive support, which rules out
every server requiring 2FA — a hard requirement for the clusters this targets.
So the design was carrying a stalled upstream dependency to obtain one feature.

**The operator set a governing principle**: compose mature dependencies, do not
write everything ourselves — it is neither safe nor reliable — and deliver
components an application imports to embed a terminal, wiring only UI and
styling.

## Decision

Tether is a set of Rust components with platform-native bindings and views.

Its value proposition is *"we composed mature engines into an embeddable,
customisable terminal with a stable API"*, not *"we wrote the engine"*. That is
the layer the ecosystem is missing: terminal applications exist, terminal
engine crates exist, the component between them does not.

Engines are composed:

| | Choice | Governance · adoption |
|---|---|---|
| SSH | `russh` | warp-tech org · 7.0M · async, keyboard-interactive |
| Crypto | `aws-lc-rs` (russh default) | aws org · 226M |
| Terminal | `alacritty_terminal` | alacritty org · 1.6M, carries `vte` at 75M |
| Bindings | `uniffi` | mozilla org · 12.5M · async fns and async callbacks |
| Runtime | `tokio` | tokio-rs org · 973M |

Components are `tether-terminal`, `tether-ssh`, `tether-core`, and later
`tether-render`, `tether-view/swift`, `tether-app/apple`. The build graph
forbids `tether-terminal` from depending on SSH, so the byte-stream boundary is
checked by `cargo tree` rather than by review.

A dependency policy (spec §5) governs additions on five criteria: governance,
activity, adoption, absence of historical baggage, licence. A personally
maintained project is acceptable **only when mainstream**, because adoption is
the real insurance — an abandoned crate with millions of downloads gets forked,
a niche one does not. `russh` and `thiserror` pass on that basis; `sugarloaf`
and `rio-vt` (91k and 58k downloads, single-project) do not, capable though
they are.

## Consequences

- The Swift-native specification is superseded in full, including its claim
  that the terminal parser, state machine and buffer belong to this project.
  That was the position the governing principle rejects.
- The vendored libssh2 and Mbed TLS trees are gone. libssh2's stalled port is
  now someone else's problem.
- Non-Apple platforms become a product decision rather than an architectural
  impossibility.
- Two dependencies carry recorded caveats: `uniffi` is MPL-2.0 (file-level
  copyleft, unencumbered for linking), and `aws-lc-rs` compiles native code, so
  building it for Apple targets from cargo alone is a Phase 0 gate.
- Phase 0 is now about the binding seam: async across FFI, an interactive
  prompt travelling upward through a callback interface, cancellation crossing
  in both directions, and the artifact shape a Swift consumer sees.

## Alternatives rejected

- **Stay Swift-native.** Cheaper today and proven to build. Rejected: it leaves
  us writing a VT engine and a renderer ourselves, keeps a large vendored C
  dependency whose upstream port is stalled, and closes the door on every
  non-Apple frontend.
- **Rust core, but write our own VT engine.** Rejected by the governing
  principle, and the evidence agrees: Ghostty, Alacritty and WezTerm each spent
  years on theirs.
- **Adopt `sugarloaf` as the renderer.** Purpose-built for exactly this and
  would save the most work. Rejected on the dependency policy, and because it
  would tie our terminal's appearance to another product's roadmap.
- **`swift-bridge` or a hand-written C ABI** instead of UniFFI. Rejected:
  async and callback maturity for the first; re-implementing UniFFI's plumbing
  for the second, which is the thing this decision exists to stop doing.
