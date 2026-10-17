# Windows renderer evaluation

Date: 2026-10-16. Branch: `evaluate/wgpu-renderer`.

**The existing Windows Rust wgpu path works on this machine. Performance is an approximate manual observation, never a CI gate.** Windows observations cannot establish iOS quality or performance. [ADR 0021](../Decisions/0021-renderer-unification-is-measurement-gated.md) is the ownership decision, and Apple presents through this same wgpu renderer.

See [the shared renderer architecture](renderer-architecture.md) for ownership and native host contracts. The Windows binding delegates layout and backend creation to that shared Rust implementation.

## Scope and reproduction

The test harness creates a visible HWND and uses the existing C# TerminalSurface → UniFFI → Rust wgpu/glyphon/cosmic-text path. A Debug-only WinUI fixture exercises the real TerminalControl. ScreenFrame, palette, selection and link contracts are unchanged; diagnostics expose no wgpu SDK types. Product backend selection is unchanged. The harness explicitly requests DX12 and records the actual adapter.

```powershell
python scripts/test-render-evaluation.py
python scripts/evaluate-renderer.py --group common
python scripts/evaluate-renderer.py --group snapshots
# Optional: pressure, idle/cursor/single-row modes, longer sampling or counters
python scripts/evaluate-renderer.py --group stress --full-matrix --seconds 5 --gpu-counters
```

Defaults are five seconds, one process per scenario, scrolling only (six common scenarios), after warmup. Use `--full-matrix` for static/cursor/line/scroll, `--seconds` and `--repetitions` when investigating a specific problem. Screenshots run separately from performance sampling. Each run isolates its binaries and rejects reused output directories. Closing the window cancels collection; GPU initialization unavailable is explicitly unverified. Exit zero means collection completed, not a performance pass.

For the real WinUI integration fixture:

```powershell
dotnet build app-win/TetherApp.Windows.csproj -c Debug -p:Platform=x64 -warnaserror
# Launch the built executable with an absolute evidence directory
TetherApp.Windows.exe --render-evaluation-output C:\Temp\tether-winui-evidence
```

This Debug-only fixture runs 90 seconds, uses two real terminal controls, recreates one repeatedly and exercises resize/minimize/restore. It loads no saved hosts or sessions and saves no preferences.

## Approximate observations

NVIDIA RTX 3070, driver 32.0.16.1692, 3840×2160 desktop, reported 143Hz, actual DPI 144 (150%), Windows build 26300, .NET 10.0.12. Fonts are Consolas / Microsoft YaHei UI at 13 physical pixels in the standalone harness. Other apps, UI checks and builds overlapped collection. This is not a controlled comparison.

The initial common batch collected 72 scenarios (30 seconds × three processes, including idle). Remaining pressure collection was intentionally stopped after the requirement changed to rough performance. No more long benchmark is required. Below is the worst p95 across dynamic modes/repetitions, useful only as a rough range:

| Grid | Shape | CPU work incl. FFI (ms) | Managed Draw (ms) | GPU pass (ms, approximate) |
|---|---|---:|---:|---:|
| 80x24 | prose | 0.96 | 1.19 | 0.09 |
| 80x24 | highlighted | 3.51 | 7.31 | 0.09 |
| 120x40 | prose | 3.01 | 3.47 | 0.30 |
| 120x40 | highlighted | 5.06 | 5.46 | 0.29 |
| 200x60 | prose | 7.34 | 7.83 | 2.65 |
| 200x60 | highlighted | 3.74 | 3.93 | 0.67 |

Common CPU work is roughly **1–7ms p95** here. A 120×40 per-cell-style scroll workload was roughly **21ms p95**, showing the expected sensitivity to run count. Neither number is a pass/fail threshold. These measurements do not establish actual displayed FPS.

The WinUI lifecycle fixture completed about 90 seconds, with 36 terminal recreations, 16 minimize/restore/resize cycles and no recorded draw exceptions. Its 5022 attempted updates are not displayed frames. Private-memory samples were about 658–1107 MiB across the application and renderer; this short stress run neither proves a leak nor establishes long-term stability.

All 12 font-grid readbacks passed the final-column row-presence smoke check. Visual spot checks cover English/CJK, combining marks, emoji/ZWJ, fallback scripts, bold/italic, decorations, selection and cursor. This is not exhaustive typography certification. Font scales 1/1.5/2 are not actual OS DPI transitions.

[100% font scale](renderer-evaluation/font-grid-100.png) · [150%](renderer-evaluation/font-grid-150.png) · [200%](renderer-evaluation/font-grid-200.png) · [400×100](renderer-evaluation/font-grid-400x100.png)

## What the numbers mean

`result.json` records cold creation, first font setup and first Draw, managed Draw percentiles, CPU use and host private bytes. `native.csv` separates binding conversion (`frame_conversion_ms`), shared metrics/layout (`metrics_layout_ms`; older traces combine both as `metrics_conversion_layout_ms`), text preparation, surface-acquire wait, render CPU work, GPU pass and present-call time. CPU work excludes acquisition/present waits; managed Draw includes them. GPU timestamps cover the render pass, excluding atlas copies, queue wait, compositor and display. Never add independent percentiles or use draw() return time as display latency.

Current traces retain submission frame IDs for exact GPU warmup filtering. The initial common batch used sample-order filtering, so its GPU values above are approximate. Static mode submits no draws after warmup. Optional process GPU-engine and GPU-memory counters are kept separately; missing metrics stay unknown. Raw counters and traces remain under the ignored artifacts directory.

Optional `--presentmon C:\Tools\PresentMon.exe` supports v2 QPC display evidence, filtered by PID, time and one swapchain. The local attempt failed with ETW access denied; no elevation or settings change was attempted. Actual presentation remains unknown and is not required for rough performance sampling. The runner never downloads external tools. See the [official PresentMon reference](https://github.com/GameTechDev/PresentMon/blob/v2.6.0/README-ConsoleApplication.md).

## Checks and next decision

CI runs builds, Rust checks, binding consistency, fixture contracts, evidence-parser tests and Windows release checks. It runs no GPU benchmark and makes no frame-time assertions. Existing prepare() cost measurements remain as ignored manual tests without timing thresholds; they do not cover GPU execution or presentation. The full common/Windows checks passed locally, including publishing; the updated parser tests and fixture checks also passed. Apple/Linux checks were not run on this Windows host.

The Windows path was credible enough to measure. Cross-monitor DPI, device loss, integrated GPUs and long-duration stability remain unverified Windows coverage. Apple drawing has since moved to the shared renderer; this report does not approve or retain a second painter. A regression is fixed on that shared path. See [ADR 0021](../Decisions/0021-renderer-unification-is-measurement-gated.md).

[Machine-readable observations and provenance](renderer-evaluation/windows-baseline.json) retain per-scenario percentiles and cold/resource readings; raw local evidence lives in `artifacts/windows-render-evaluation/`. Supplied cached binaries are identified by hashes; recorded source hashes alone do not prove their build provenance.
