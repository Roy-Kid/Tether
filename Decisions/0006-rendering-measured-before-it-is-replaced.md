# 0006 — Rendering is measured before it is replaced

Status: accepted
Date: 2026-09-18
Phase: 4 (opening)

## Context

Spec §23 says the GPU text stack is chosen in Phase 4 **by measurement**, and
§20 says to optimise after profiling. The app shipped a SwiftUI `Canvas`
renderer — `TetherUI.TerminalView` — and no frame had ever been timed. A
decision "by measurement" with no measurement is a decision by assumption,
whichever way it goes: reaching for `wgpu` because a terminal "obviously needs
a GPU" would have been the same mistake in the other direction.

So the first Phase 4 work is not a renderer. It is a number.

## What was measured

Two harnesses, because the frame is built on one side of the FFI boundary and
drawn on the other:

- `cargo run --release -p tether-ffi --bin frame-cost` — reading the engine's
  grid into a `Screen` and collapsing it into the `ScreenFrame` a frontend
  draws, over the recorded corpus workloads.
- `swift test --package-path app/Packages/TetherFrontend --filter RenderCost` —
  drawing a `ScreenFrame` through the same `TerminalView` the app uses.

Neither measures uniffi's lowering between them, and the Swift half
rasterises through `ImageRenderer` rather than through the compositor. Both
caveats are stated in the harnesses. What dominates — one attributed string
resolved and drawn per run — is the same on the app's path.

Measured on an Apple M4, 24 GB, macOS 27.0 (26A428), release build:

| Frame production (Rust) | 80x24 | 120x40 | 200x60 | 400x100 |
|---|---|---|---|---|
| `vim` | 40µs | 90µs | 238µs | 795µs |
| `dashboard` | 41µs | 94µs | 226µs | 760µs |
| every cell its own colour | 64µs | 125µs | 398µs | 1.3ms |

| Drawing (SwiftUI Canvas) | 80x24 | 120x40 | 200x60 | 400x100 |
|---|---|---|---|---|
| prose (1 run per row) | 2.2ms | 1.1ms | 1.7ms | 3.6ms |
| highlighted (6 runs per row) | 4.0ms | 6.2ms | 10.1ms | 19.1ms |
| every cell its own colour | 40ms | 100ms | 250ms | **893ms** |

The shape is the finding: **drawing costs 21–30µs per run and is otherwise
indifferent to how big the screen is.** Frame production is linear in cells and
never the bottleneck — at its worst it is a twentieth of the drawing.

## Decision

1. **The SwiftUI `Canvas` stays** for now. It draws an ordinary terminal —
   a shell, a pager, a syntax-highlighted editor — inside a 60Hz frame at every
   size a person can produce, and it is a few hundred lines with no GPU
   resources to own. Replacing that on a hunch would be the layer §22 forbids.

2. **The trigger for the GPU stack is written down**, so Phase 4 starts from
   evidence rather than from appetite. Any one of:
   - an ordinary workload (prose or highlighted) measuring past 16.6ms at a
     size people use;
   - a cell-coloured workload — `btop`, an image viewer, a full-colour TUI —
     being a use case we commit to, since at 21µs per run those are already
     tens of frames behind;
   - a per-run cost that stops being flat, which would mean the cost has moved
     somewhere this measurement cannot see.

3. **The measurement is a test, not a memory.** `RenderCostTests` asserts an
   ordinary frame stays under 60ms and that the per-run cost stays under
   100µs. Both ceilings are generous — a CI machine is slower than a laptop,
   and a performance test that flakes gets deleted rather than fixed. They
   catch an order of magnitude, which is the size of regression that makes a
   terminal unusable.

## What this does not decide

The worst case is bad and is recorded as bad: 893ms for a screen where every
cell carries its own colour. Nothing here fixes it, and the ceiling in the test
is deliberately a rate rather than that number, because asserting the number
would be asserting the problem.

Two paths are open when the trigger fires, and this ADR picks neither:

- **Stay on CoreGraphics, draw fewer things.** One shaped line per row instead
  of one per run. The comment in `TerminalView` explains why that is not free:
  a terminal is a grid, and letting the text system choose advances drifts out
  of alignment where a row mixes wide characters with narrow ones.
- **Go to the GPU** — `wgpu` with a glyph atlas, which is what §5's criteria
  were written to judge.

The second is more work and more surface. Neither is justified by today's
numbers, and the numbers are now something the next person can re-run in two
commands rather than re-argue.
