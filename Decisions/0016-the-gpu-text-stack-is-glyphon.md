# 0016 — The GPU text stack is glyphon

Status: accepted
Date: 2026-09-23
Phase: 4 (Windows rendering)

## Context

Spec §4 names `wgpu`, `cosmic-text`, and a GPU text layer — `glyphon`, or
`parley` + `vello` — "decided in Phase 4 by measurement". Spec §23 repeats it:
the GPU text stack is chosen here, by measurement.

Phase 4 has since measured the *existing* path (Decisions/0006): the SwiftUI
`Canvas` renderer draws an ordinary terminal well inside a 60Hz frame and
stays on Apple. That decision does not transfer to Windows. There is no
CoreGraphics there and no SwiftUI `Canvas` to keep, so Windows needs
`tether-render` — the component the spec always named — and with it a GPU
text stack.

Two candidates were on the table, and one that looked like a shortcut:

| Candidate | What it is | Verdict |
|---|---|---|
| `glyphon` | GPU text middleware: `cosmic-text` shaping + `etagere` atlas + draw into *our* `wgpu` render pass | **chosen** |
| `parley` + `vello` | rich-text *layout* (HarfRust, ICU4X, fontique) + a GPU 2D *scene* renderer | rejected |
| `sugarloaf` | Rio's whole terminal renderer | rejected again, ADR 0001 |

## Why glyphon

1. **It is the right shape.** A terminal renderer owns its frame: clear
   colour, background quads, selection, cursor. What it needs from a text
   stack is *placed glyphs on a caller-chosen grid*. glyphon is middleware —
   it records text into the render pass we already own. `TerminalView`'s
   comment is the same lesson from the other side: letting a text system
   choose advances drifts out of alignment where a row mixes wide and narrow
   characters. We place runs at columns; glyphon draws what we place.

2. **parley is the wrong layer.** It is a rich-text layout engine — line
   breaking, bidi reordering, editing, selection. A monospace terminal grid
   does not want a layout engine choosing advances; it wants `columns /
   characters` spacing onto an integer cell, which is exactly what
   `FontMetrics.tracking` already does on Apple. Taking parley to draw one
   string per run would be outsourcing our grid to a component built for
   paragraphs. vello would then own the frame rather than join ours.

3. **cosmic-text is already in the stack.** Spec §4 names it as the shaper.
   glyphon's shaping and rasterisation *are* cosmic-text (`etagere` for
   atlas packing, `wgpu` for submission). Choosing parley would replace
   cosmic-text with HarfRust + fontique + skrifa + ICU4X — four crates where
   the spec already chose one.

4. **§5's five criteria, judged and written down.**
   - *Governance*: grovesNL/glyphon is small, but it is infrastructure (a
     glyph atlas), not architecture. §5 asks this question — *mature
     primitive, or outsourcing our architecture?* — and glyphon is a
     primitive. sugarloaf failed this test as architecture; glyphon does not.
   - *Activity*: current releases; tracks `wgpu`.
   - *Adoption*: the default GPU text path for `wgpu` terminals and 2D UIs.
   - *No historical baggage*: written for `wgpu`, no abandoned platform APIs.
   - *Licence*: Apache-2.0 / zlib / MIT, at the user's option. Record the
     triple for the licence review the way `uniffi`'s MPL was recorded.

5. **sugarloaf stays rejected (0001).** Windows does not reopen it. It
   brings rio-* workspace crates, a Metal/Vulkan/wgpu split that makes
   Windows a second-class backend, its own swash text stack beside
   cosmic-text, and Rio's appearance. "Purpose-built and would save the most
   work" is still true and still the wrong trade for an SDK that sells a
   stable, customisable API.

## Decision

`tether-render` composes `wgpu` + `cosmic-text` + `glyphon`. What we write is
the terminal-specific part only (spec §14): grid layout, damage-driven
partial redraw, cursor, selection, the theming surface.

`parley` + `vello` is not adopted and not kept warm. If glyphon ever fails
the five criteria, the replacement is chosen the same way — by measurement,
in an ADR — not by reaching for whatever is adjacent.

## The measurement stays a test

0006's third decision transfers in full: *the measurement is a test, not a
memory*. `tether-render` carries the same three shapes and four sizes, and
the same rate ceilings:

| Shape | Meaning |
|---|---|
| `prose` | one run per row |
| `highlighted` | six runs per row |
| `worstCase` | one run per cell |

| Size | 80x24 | 120x40 | 200x60 | 400x100 |
|---|---|---|---|---|

Ceilings, deliberately generous so a CI machine does not flake the test into
deletion: an ordinary frame under **60ms**, and the worst case asserted as
**100µs per run** — a rate, not the known-bad absolute from 0006's
CoreGraphics numbers (893ms at 400x100). Those numbers describe the path
this replaces on Windows; asserting them would be asserting the problem.

### Measured, `cargo test -p tether-render --release` (2026-09-23)

Prepare-only (frame → draw list), the half 0006 called "drawing":

| | 80x24 | 120x40 | 200x60 | 400x100 |
|---|---|---|---|---|
| prose | 0.00ms / 0.08µs | 0.00ms / 0.07µs | 0.00ms / 0.07µs | 0.01ms / 0.08µs |
| highlighted | 0.02ms / 0.11µs | 0.02ms / 0.08µs | 0.03ms / 0.09µs | 0.05ms / 0.08µs |
| worstCase | 0.20ms / 0.11µs | 0.48ms / 0.10µs | 1.05ms / 0.09µs | (not asserted) |

The shape 0006 recorded as tens of frames behind on CoreGraphics — every
cell its own colour — is **0.09–0.11µs per run** here, against 21–30µs on
the `Canvas` path. Two orders of magnitude, and the per-run rate is flat,
which is the third of 0006's GPU triggers answered in the other direction:
the cost has *not* moved somewhere this measurement cannot see.

What is measured is `prepare`, not `glyphon`'s atlas upload or a present.
The GPU half gets its own harness the way 0006 split frame-production from
drawing; until then these numbers are the layout half and are labelled as
such in the test's stdout.

## Consequences

- `cargo run --release -p tether-ffi --bin frame-cost` stays as the
  frame-production half. `tether-render`'s cost test is the drawing half,
  the way `RenderCostTests` was on Swift.
- Apple keeps `TetherUI.TerminalView` and `RenderCostTests` until 0006's
  triggers fire. Nothing here replaces CoreGraphics on macOS or iOS.
- Backend confinement extends: `wgpu`, `glyphon` and `cosmic-text` types
  stop inside `tether-render` the way `alacritty_terminal` stops inside
  `tether-terminal` (spec §8). The public surface is draw lists and metrics,
  not GPU objects.
