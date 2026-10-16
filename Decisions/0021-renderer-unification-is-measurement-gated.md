# 0021 — Renderer unification is measurement-gated

Status: accepted (evaluation direction, not Apple migration approval)
Date: 2026-10-16

## Decision

Target Rust terminal core + Rust wgpu renderer + platform-native UI. Start by
validating the existing Windows wgpu/glyphon/cosmic-text path through the C#
façade, a real HWND and the actual WinUI TerminalControl. Keep Apple Swift Metal
as the shipping implementation and comparison baseline.

A workable Windows path supports considering an Apple comparison prototype;
Windows timing numbers alone never authorize replacement of the Apple renderer. On Apple, wgpu would still use Metal; AppKit and UIKit remain
responsible for native views, input, accessibility and platform lifecycle.

Unification is a possible measured outcome. If iOS font quality, performance,
power, memory or integration is materially worse, retain its independent Swift
Metal implementation. macOS and iOS can make different decisions.

## Shared backend boundary

The target renderer is one Rust implementation with platform-specific surface
attachment. Windows experiments exercise that shared path now. Backend instance
policy and HWND attachment live inside `tether-render`; UniFFI/C# only convert
contracts. `TerminalRenderer::draw_frame` owns metrics, layout and submission for
native hosts. The FFI crate has no direct wgpu dependency.

Future macOS/iOS adapters attach native surfaces and use wgpu's Metal backend;
they reuse the same draw path. Native AppKit/UIKit ownership, fonts, packaging
and lifecycle still need Apple integration and comparison before switching.
See [the concrete architecture and host contract](../docs/renderer-architecture.md).
No placeholder Apple API or generic renderer/plugin framework is introduced.

## Evidence and performance policy

Hardware performance is an approximate, manual engineering observation, never a
CI gate. GPU, driver, DPI, fonts and background work affect timings. Default to
short representative samples; extend duration or repeat only when investigating
an observed problem. No fixed frame-time or missed-refresh threshold determines
pass/fail or permission to begin an Apple prototype.

CI checks compilation, bindings, fixture contracts and evidence parsing. Existing
layout-cost measurements remain available as ignored manual tests, without timing
assertions. They measure prepare(), not shaping, GPU execution or presentation.

Use opt-in `render-diagnostics` builds for CPU stages, asynchronous GPU pass
timestamps and separate screenshot readback. Do not equate draw()/present()
return time with display latency or sum independent percentiles. Optional ETW
and GPU counters add context; unavailable observations remain explicitly unknown.
Correctness and lifecycle failures still need fixing. Actual cross-monitor DPI,
device loss and long-duration stability require separate checks when relevant.
A single Windows GPU cannot establish iOS typography, power or memory behavior.

## Consequences

- Windows measurement has reproducible tooling and checked-in assessment tests.
- The SDK's screen/overlay contract and native UI ownership remain unchanged.
- This decision adds no Apple surface FFI, GPU dependency in the XCFramework or
  default renderer setting. A future Apple prototype must explicitly design
  layer ownership, threading, font access, DPI and background/foreground recovery.
- The outcome and outstanding evidence live in
  [the Windows evaluation report](../docs/renderer-evaluation.md). This ADR does
  not supersede 0016's text stack or 0017's artifact shape.
