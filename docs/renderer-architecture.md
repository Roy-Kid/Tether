# Shared wgpu renderer with native hosts

Status: target architecture; Windows is the first implementation and experiment.
Apple currently ships its existing Swift Metal renderer. See ADR 0021 and the
[Windows observations](renderer-evaluation.md).

## Ownership

```text
Rust terminal core → ScreenFrame + palette + selection/link overlays
                                │
                     C# / Swift binding conversion
                                │
                 tether-render::TerminalRenderer::draw_frame
                     metrics → grid layout → draw list
                     cosmic-text → glyphon → wgpu
                                │
                     platform presentation surface
                      Windows          Apple (future)
                      HWND             native Metal layer
                      DX12 experiment  Metal backend
```

The shared backend is `tether-render`, with one implementation of cell geometry,
Unicode layout/shaping, glyph caching, backgrounds, cursor, decorations,
selection, links and GPU submission. Platform adapters attach surfaces; they do
not fork these algorithms. Terminal state, transport and session ownership remain
outside the renderer. No GPU or UI dependency is added to the terminal core.

| Layer | Owns | Does not own |
|---|---|---|
| Rust terminal core | VT state, ScreenFrame, damage and input encoding | Fonts, windows, GPU |
| C#/Swift facade and UniFFI | Contract conversion and application calls | Backend selection, shaping, GPU objects |
| Shared Rust renderer | Font measurement, layout, text caches, pipelines, submission, surface configuration | Native input, native view tree, session storage |
| Rust platform attachment | Instance policy, native surface creation, handle safety | Terminal-specific drawing |
| WinUI / AppKit / UIKit host | Native view, input/IME, clipboard, accessibility, DPI, scheduling and lifecycle | A second copy of wgpu rendering algorithms |

## Implemented Windows seam

`TerminalRenderer::attach_hwnd` creates the GPU instance and attaches a live
host-owned HWND. Backend/environment selection lives in `platform.rs`, preserving
existing product policy. The manual experiment requests DX12 explicitly.
`tether-ffi` no longer directly depends on wgpu or constructs an instance.

`TerminalRenderer::draw_frame` is the shared frame entry point. It measures the
selected fonts, prepares grid geometry and overlays, then runs the existing GPU
renderer. The binding only converts ScreenFrame/palette/overlay DTOs. Existing
measure/set_fonts/resize calls retain their public signatures and ScreenFrame
remains the input contract. Lower-level Rust draw-list/surface APIs remain for
existing Rust integrations; C#/Swift APIs expose no wgpu types.

The real Windows TerminalControl and HWND experiment both call this same path.
Diagnostics separate binding conversion from shared metrics/layout, text prepare,
GPU pass and CPU waits. Performance observations are manual, approximate and never
CI thresholds. Screenshots are captured separately from performance sampling.

## Native host contract

- Sizes and font sizes passed to the renderer are physical pixels. Hosts convert
  DIPs/points using their current native scale exactly once. Layout, pointer hit
  testing and terminal row/column sizing use the same returned font metrics.
- The host owns the native window/view/layer. Stop scheduling, finish in-flight
  calls and dispose the Rust surface **before** destroying that native object.
  A handle is borrowed; passing an integer never transfers ownership.
- Serialize draw, resize and font changes for a surface. The FFI surface lock
  protects renderer state; platform UI thread rules still belong to the host.
  An asynchronous attachment must keep the native target alive until completion,
  including cancellation. Apple main-thread/layer requirements need explicit
  treatment in its adapter; Windows behavior is not a substitute for that work.
- The host coalesces damage/redraw requests and owns the platform frame callback.
  Idle terminals need no repeated draw calls. Native IME and accessibility stay
  with native views, using terminal geometry from the shared contract.
- Resize and DPI changes refresh physical dimensions and metrics together.
  Suspend scheduling while hidden/backgrounded or zero-sized. On resume refresh
  dimensions and request a full redraw.
- Current surface errors propagate to the host's recovery path. Recreate only
  after stopping use of the old surface; restore fonts, metrics, palette and the
  latest frame. Device-loss recovery is not yet demonstrated or generalized.

## Apple attachment and switching

A future Apple change adds a narrowly scoped native surface attachment inside the
renderer platform module and a matching binding constructor. AppKit/UIKit own the
view/layer and input/lifecycle; wgpu selects its Metal backend. The adapter feeds
the existing `draw_frame` path rather than porting shaders/layout into Swift.
No Apple pointer constructor is invented or exported before its lifetime and
threading contract is tested on Apple hardware.

The Apple renderer build remains opt-in: the current XCFramework does not acquire
a GPU stack from this Windows refactor. A prototype must enable/package the Rust
render feature for macOS, iOS device and simulator targets, generate matching
bindings, and provide usable system/bundled fonts to cosmic-text. Font access and
fallback are an integration task, not guaranteed by enabling the Metal backend.

At the native view composition point, select either current Swift Metal or shared
Rust wgpu for an entire surface. Keep ScreenFrame, palette, overlays, input and
layout measurement paired with the selected renderer. Drop the old surface before
switching; do not mix metrics from one renderer with pixels from the other.
Use the same recorded frames for comparison. There is no public renderer-toggle
setting until an Apple prototype supplies both working implementations.

This prepares code reuse, not a zero-work platform switch: Apple surface ownership,
font access, packaging and foreground/background behavior still need real native
adapters. Once those adapters are verified, platforms reuse the Windows-tested
renderer without another rendering implementation. Compare font quality, rough
frame cost, memory and power against current Swift Metal on actual macOS/iOS.
If iOS materially regresses, retain its independent implementation; macOS can
adopt wgpu separately.

## Windows refactor validation

The shared path completed six real-HWND DX12 smoke scenarios (80×24, 120×40,
200×60; prose and six-run highlighting; two seconds each after warmup).
Traces observed both binding conversion and shared renderer layout, plus GPU
render-pass timestamps. This used a Debug native library to verify the calling
path, not to compare performance with the earlier Release baseline. Actual
presentation cadence remains unmeasured. The evidence parser has 12 regression
tests, including accounting for the new separation of conversion and layout.
