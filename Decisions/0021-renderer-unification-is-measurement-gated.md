# 0021 — One shared renderer; release qualification is measured

Status: accepted architecture; hardware release qualification remains explicit
Date: 2026-10-16

## Decision

Windows, macOS and iOS converge on one Rust terminal renderer:
`wgpu + cosmic-text + glyphon`, with native UI hosts. Windows keeps its current
backend policy; Apple uses wgpu's Metal backend. macOS and iOS switch in the same
release. Independent Swift Metal and Canvas terminal painters are removed from
the final implementation. Legacy public view/drawing names forward to wgpu.

This supersedes the earlier allowance for a permanently independent iOS renderer
and the Apple-specific retention notes in ADR 0016. A regression is fixed in the
shared path or a narrow native integration adapter. If it is unresolved, delay
the combined Apple release; roll back versions rather than maintaining two
production drawing implementations.

## Boundaries

The renderer owns terminal pixels: geometry, font metrics, shaping, fallback,
glyph caching, backgrounds, decorations, selection, links and cursor submission.
Hosts own windows/layers, native input/IME, clipboard, accessibility, scheduling,
DPI and lifecycle. Bindings map contracts and never construct terminal pipelines.
The terminal core remains headless and free of UI/GPU dependencies.

Apple layer capture is synchronous on the main thread; async device initialization
retains the target through completion/cancellation. Calls are serialized per
surface and explicit close precedes native target destruction. Damage caching is
shared. Fonts retain native defaults and can be selected/imported in settings;
CoreText discovers Apple resources but does not shape or rasterize terminal text.
See [the concrete host contract](../docs/renderer-architecture.md).

## Evidence and release policy

The existing [Windows report](../docs/renderer-evaluation.md) remains historical
DX12 evidence. It does not establish Apple performance, power or typography.
The [Apple implementation report](../docs/apple-renderer-evaluation.md) records
current pixel/build tests, short macOS observations and remaining device checks.

CI checks compilation, generated bindings, source boundaries, layout/damage and
actual GPU pixel output. Screenshot readback is separate from timing. Hardware
performance uses short representative manual samples with explicit provenance,
never a fixed CI frame-time or missed-refresh threshold. Draw/present return
latency is not displayed latency; independent percentiles are never summed.

Before releasing the combined Apple switch, qualify actual macOS and iOS devices:
native font/fallback quality, scale/rotation/IME, rapid attach/detach, background
recovery, multi-terminal memory, CPU/GPU and power observations. Keep unavailable
measurements explicitly unknown. Passing a compile or simulator test is not a
substitute for device qualification and must not be reported as one.
