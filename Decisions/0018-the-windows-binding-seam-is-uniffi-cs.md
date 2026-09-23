# 0018 — The Windows binding seam is UniFFI's C ABI and a C# projection

Status: accepted
Date: 2026-09-23
Phase: 4 (Windows)

## Context

A WinUI 3 host is C#. The session API lives in `tether-ffi` as UniFFI
proc-macro exports: objects, records, enums, foreign async traits
(`InteractivePrompter`, `HostTrust`, `TransferProgress`), and Tokio-backed
futures. Swift already consumes that surface through generated bindings
(Decisions/0003, 0004). Windows needs the same surface in C#.

Three ways to get there:

1. **`uniffi-bindgen-cs`** (NordSecurity) — generates the C# from the same
   library metadata the Swift generator reads.
2. **A hand-written C ABI + P/Invoke** — the generated `TetherFFI.h` is 1272
   lines of uniffi's async and callback machinery (`UniffiRustFuture*`,
   `UniffiForeignFuture*`, vtables). Hand-writing that is re-implementing
   UniFFI's plumbing, which Decisions/0001 rejected for `swift-bridge`.
3. **A Rust `windows-rs` control** calling `tether-core` directly — no
   bindings, but WinUI types then reach into the SDK and XAML authoring
   becomes a Rust problem (law: the SDK does not know its consumers).

## Decision

**`uniffi-bindgen-cs`, checked in, wrapped by a C# façade.**

- Generator: `uniffi-bindgen-cs v0.11.0+v0.31.0`, which pairs with uniffi
  0.31. The workspace pins `uniffi = "0.31"` for that reason: 0.32's metadata
  is not readable by the generator (`Invalid string data`).
- Output: `dotnet/Tether/Generated/tether_ffi.cs`. Generated types are
  `internal`, which is the façade isolation 0004 wants — a consumer cannot
  name `FfiConverterTypeSession` any more than a Swift consumer can name
  `TetherFFIBindings`.
- Façade: `dotnet/Tether`, the only published product. It re-exports the
  contract (`TerminalSession`, `ScreenFrame`, `TerminalInput`,
  `TerminalPalette`, `HostTrust`, …) with C# naming and no UniFFI types.
- Foreign traits work: `HostTrust` and `InteractivePrompter` cross as C#
  interfaces with async methods, which is what SSH auth needs.

## Consequences

- `scripts/build-windows.ps1` fails if `uniffi-bindgen-cs` is missing. It is
  a developer/CI tool, never a consumer tool (spec §21).
- A C# consumer that needs a type the façade does not export is a façade gap,
  not a reason to reach into `Generated/`.
- When `uniffi-bindgen-cs` publishes a 0.32 pairing, unpin uniffi and
  regenerate. The seam does not change.

## What this does not decide

Kotlin/Python/Ruby bindings, or a C++/WinRT projection. UniFFI can generate
those from the same surface; nobody has asked.
