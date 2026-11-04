# Tether UI contract

Cross-platform rules that the token sources do not already state. This file
does not restate their numbers. A figure here that disagrees with a source
below is stale.

External terminal apps inform hierarchy and interaction. They do not supply
tokens, and their rendering does not replace SwiftUI, AppKit or WinUI.

## Authority

| What | Where |
| --- | --- |
| Window chrome law (icon-only, compact strip, alerts) | `.claude/notes/law.md`, `app-ui-chrome` |
| Mac workspace shape | `design/compact-zen/final/SPEC.md` |
| Apple colour, type, spacing, radii, state opacities | `Theme` and `UIStyle` in `app/Packages/TetherFrontend/Sources/TetherUI/Chrome.swift` |
| Apple window metrics | `Chrome` in `app/Sources/TetherApp/Design.swift` |
| Windows roles | `app-win/Design.xaml` |
| Windows caption and status composition | `app-win/MainWindow.xaml` |
| Release check sizes | `docs/ui-calibration.md` |

Those check sizes are calibration frames. The window minimum is
`Chrome.windowMinWidth` and `Chrome.windowMinHeight`.

`design/compact-zen/final/*.svg` are illustrations. Their palette and
status prose are not tokens. The app icon is not the accent colour.

Use the named role. A nearby literal is not a new token.

## Kept apart on purpose

macOS puts a new tab, a split, zoom and Zen in the menu bar and the command
menu. Windows uses the native caption and `TabView`, including that control's
add button. Windows does not copy traffic-light offsets, AppKit titlebar
hooks, SF Symbols or a menu bar. Rows may grow with text scaling. Matching a
Mac pixel is not the acceptance test.

Mac selection is the accent wash (`UIStyle.selectionOpacity`). A split pane's
tab also draws `UIStyle.Mark.rule` along its bottom edge. Windows selected
tabs use `TerminalCanvasBrush`; unselected tabs stay transparent. That rule
is not a Windows control.

Terminal inset belongs to the platform that draws it:
`TerminalSurface.defaultInset` on Apple, `TerminalInset` in `Design.xaml` on
Windows.

Host search uses `UIStyle.title`. The command field uses `UIStyle.input`.
Host management rows use `UIStyle.Mark.tileWidth` and `tileHeight`. Compact
choosers stay on the compact roles. These rows stay separate.

Accent means selection or an action. Connected uses the success role.
Warning and danger are exceptional status. Selection is separate from
keyboard focus. The opacities are the named `UIStyle` values.

The terminal is not wrapped in a rounded card. A dragged Mac tab reorders
or splits (`TabDrag`); it does not tear off a window. The Windows `TabView`
does not drag or reorder tabs. The tab strip has no profile menu. Settings
stay a separate window, and the Default profile picker stays there.

Chrome colours are the platform's semantic colours. Appearance does not
freeze one luminance order. The terminal palette is independent of chrome
appearance.

Frosted Glass and the shared backdrop are `WorkspaceAppearance` and
`WorkspaceBackdrop` in `Design.swift`. An opaque clear, and glyph edges on
a transparent background, are the terminal render tests. On Windows the
workspace backdrop is the main window's Mica Alt, and the host chooser uses
`DesktopAcrylicBackdrop`. The terminal canvas brush stays the opaque palette
colour. WinUI owns focus, contrast, disabled transparency and power-saving
fallbacks.

## Fixture

`--ui-preview` and `--ui-preview --light`, in `app-win/MainWindow.Preview.cs`,
show the real workspace XAML in the same offline twenty-tab state as
`InterfacePreviews.swift`. The fixture loads no settings, terminals, SSH
config or credentials.

Host-chooser placeholder and empty copy are the strings in
`WorkspaceChrome.swift` and `MainWindow.xaml.cs`.
