# 0017 — The Windows artifact is a DLL, an import lib and checked-in C#

Status: accepted
Date: 2026-09-23
Phase: 4 (Windows)

## Context

Decisions/0004 fixed the Apple shape: a prebuilt `TetherFFI` XCFramework, UniFFI's
generated Swift checked in, and a Swift façade as the only published product —
so a consumer builds with Xcode alone, no Rust, no CMake, no network (spec §21).

Windows needs the same claim and the same proof. A WinUI 3 consumer builds
with MSVC and the Windows SDK. Nothing in that toolchain compiles Rust.

## Decision

Three targets, and a consumer sees only the third — the 0004 discipline,
with the platform's own artifact names:

| Target | Shape | Rule |
|---|---|---|
| `tether_ffi` | `tether_ffi.dll` + `tether_ffi.dll.lib` (import) + `tether_ffi.pdb` | CI-built from pinned sources. Release asset, never a committed binary. |
| `tether_ffi.cs` | `uniffi-bindgen-cs` output, **checked in** under `dotnet/Tether/Generated/` | Rewritten by `scripts/build-windows.ps1`; CI fails on a diff. Never hand-edited. |
| `Tether` | C# class library (`dotnet/Tether`), the façade | The only target in `products`. Generated symbols stay `internal`. |

A `render` feature on `tether-ffi` pulls `tether-render` (wgpu + glyphon) into
the same DLL, so a consumer links one binary for session *and* draw. Apple
builds leave the feature off and keep the XCFramework free of a GPU stack
until 0006's triggers fire.

## Consequences

- `scripts/build-windows.ps1` is the source of truth: `cargo build --release
  -p tether-ffi --features render --target x86_64-pc-windows-msvc`, then
  `uniffi-bindgen-cs --library …` into `dotnet/Tether/Generated/`.
- `scripts/verify-consumer-build.ps1` mirrors 0004's enforcement: strip
  `cargo`/`rustc`/`cmake` from PATH, build a sample consumer against the
  prebuilt `.lib`/`.dll`, and type-check a file that must **fail** (generated
  symbols unreachable through `Tether`) with a positive control that must
  succeed. `-parse` accepting anything syntactically valid is why the control
  exists (0004 learned this).
- The first tagged release moves the DLL from a `path:` to a `url:` + hash.
  No URL is written here, because none exists yet.
- `uniffi` is pinned to 0.31 while `uniffi-bindgen-cs` v0.11.0+v0.31.0 is the
  current C# generator. 0.32's metadata is not readable by it. Revisit when a
  0.32 pairing ships (Decisions/0018).

## What this does not decide

Arm64 Windows slices, MSIX packaging, and a NuGet feed. Those arrive when the
x64 consumer gate is green.
