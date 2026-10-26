# Windows window materials

Settings → Appearance selects Acrylic (default), Mica or Solid. Background
opacity is one native workspace tint, initially 60%, from 50% to 100%, matching
macOS. It never
changes the opacity of glyphs, cursor, ANSI colours or explicitly coloured cells.
100% makes the workspace opaque. Solid also makes the entire window opaque and
remembers the tint for later use. Previously stored values below 50% resolve to
50%; missing or non-finite values use 60%.
Both normal and Quick Terminal windows use the same appearance preferences.

The app uses WinUI's `DesktopAcrylicBackdrop`/`MicaBackdrop`, which own activation,
theme, system transparency and power-policy fallbacks. When advanced effects are
disabled or high contrast is enabled, the workspace tint becomes opaque. Changes
are observed on the UI dispatcher; closing a window releases the event handlers.
The app never changes Windows settings.

The native settings observer batches broadcasts: a synchronous burst of 100
setting messages produces one queued refresh. Capability reads happen in that
refresh, not in each terminal's draw. Existing workspace background brushes and
resolved render palettes are reused. The top-tab layout is unchanged.

## Compositor contract

The native child HWND retains input, clipping, DPI and lifecycle ownership. It
opts into composition with `WS_EX_NOREDIRECTIONBITMAP` and has no GDI background
brush. Rust's HWND attachment recognizes that flag and creates a DX12
`DxgiFromVisual` surface using wgpu's built-in DirectComposition integration.
Its alpha mode is premultiplied, matching the existing shared render pass.
The workspace root supplies the palette-coloured tint across the header, terminal
padding, panes and empty areas. Intermediate canvas/tab backgrounds are clear.
The logical terminal palette remains opaque (including the palette reported to
the session). Just before drawing, the host sets only the default GPU background
alpha to zero for glass or one for solid, matching macOS's `renderPalette` path.
wgpu never applies a second workspace tint. Material/opacity changes refresh this
composition without recreating the HWND.

Ordinary SDK HWND attachments keep the existing backend selection policy.
Apple's CAMetalLayer path is unchanged. No wgpu type, new surface API, terminal
pipeline or compositor implementation is added to the public bindings.

Explicit `WGPU_BACKEND` values other than `dx12`, or
`WGPU_DX12_PRESENTATION_SYSTEM=Hwnd`, retain the opaque compatibility path in the
app. Such child HWNDs keep redirection and their GDI brush. These are diagnostic
overrides, not appearance controls; restart after changing them.

## Verification

Build/tests are deterministic checks. Desktop material/composition inspection is
manual and never a CI performance threshold.

```powershell
dotnet run --project tests/render-evaluation -c Release -- --composition-check
```

This shell-free desktop fixture renders three real child HWND surfaces over
the same blue/coral parent. Check that alpha 0 reveals both colours, 0.35 tints
them once, and 1 is fully opaque; text and emoji should remain visible in each.
The fixture closes after 30 seconds and drops surfaces before destroying HWNDs.
This verifies presentation/composition, not Acrylic itself.

The Debug app's existing `--render-evaluation-output <directory>` fixture uses
real WinUI TerminalControls, synthetic frames and the default Acrylic material.
It opens no session and reads/writes no user preferences. It exercises two panes,
repeated surface creation/destruction, resize and minimize/restore for 90 seconds,
writing errors/events to `winui.json`. It is a functional exercise, not a frame
time acceptance test.

Before release, visually inspect normal and Quick Terminal with a patterned
window behind them: dark/light themes; all three materials; 50/60/100% tint;
solid → Acrylic without a restart; selection, inverse video, coloured cell
backgrounds and cursor; dialogs/inspectors; 100/150/200% DPI and cross-monitor
movement. Inspect system transparency disabled, high contrast and battery saver
on suitable hardware. A compositor fixture alone does not qualify these cases.

Before the workspace-tint convergence, observed locally on 2026-10-20 with an NVIDIA GeForce RTX 3070 (driver
32.0.16.1692): the three DX12 composition surfaces rendered/disposed successfully;
visual inspection showed the blue/coral parent through the first two surfaces
and an opaque third surface. The WinUI fixture completed 90 seconds, 36 surface
recreations and 16 minimize/restore/resize events with zero recorded render
failures. Its sampled private bytes were about 959 MiB initially and 989 MiB at
the end; handles were 1249 and 1347. These short process observations do not
establish a long-term leak bound or hardware performance qualification.
Raw local evidence is in ignored `artifacts/windows-glass/winui/winui.json` and
`artifacts/windows-quick-terminal/glass-composition.log`. The release visual
matrix above, including live material changes, high contrast, battery saver and
cross-monitor behaviour, remains manual qualification.

After convergence, the native workspace tint and clear-GPU-background path
completed the same 90-second WinUI exercise with 38 surface recreations,
17 minimize/restore/resize events and zero recorded render failures. Evidence:
`artifacts/windows-glass/converged-winui/winui.json`. Windows regression cases
match the macOS `WorkspaceAppearanceTests` for stored-value bounds and
accessibility fallbacks; palette checks verify that only the default GPU
background alpha changes. macOS sources are unchanged and were not executed on
this Windows host.

References: [WinUI system backdrops](https://learn.microsoft.com/en-us/windows/apps/develop/ui/system-backdrops),
[wgpu DX12 presentation systems](https://docs.rs/wgpu/30.0.0/wgpu/enum.Dx12SwapchainKind.html).
