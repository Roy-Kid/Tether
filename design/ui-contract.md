# Tether UI contract

Current Windows direction: **Windows Terminal** is the visual reference only.
macOS remains the operation reference: a new tab uses the startup profile,
closing a background tab keeps the selection, the last tab closes the window,
the host chooser stays in the status bar, settings stay a separate window, and
files stay the current tab's inspector. Do not add a profile dropdown, tab drag,
tear-off, or in-tab settings. The Mac selected-tab underline and the 12-unit
canvas inset are not Windows chrome. Use native tabs, integrated caption
buttons, and a visible new-tab button that opens the startup profile.

Settings / Appearance / Application theme offers Use system theme, Dark and Light.
The choice persists and applies immediately to all windows and existing/new
terminal sessions. Chrome uses native theme resources; terminal rendering and
terminal color-query responses use the same existing dark/light palette. Old
settings files default to system appearance without losing their shell choice.
Compilation and settings round-trip checks passed; interactive checks are left
to the user, as requested.

Startup and every new tab open the selected local profile. Settings now exposes
Startup / Default profile: PowerShell (7 when installed, Windows PowerShell
fallback), Windows PowerShell, Command Prompt (cmd), and WSL (default distribution).
Resolve executable paths before starting a session. Selection changes affect new
tabs; existing sessions continue unchanged. The old OpenLocalOnStart flag is retired.

Native TabCloseRequested handles middle-click, the close button and Ctrl+F4;
Ctrl+W uses the same close path. Closing a background tab preserves selection;
closing the last tab closes the window. Actual smoke tests started all four shells,
received terminal output and disposed them. Workspace regression checks passed for
background, selected and final-tab closing. Build passed without warnings.

The product is a quiet terminal workspace: compact navigation, dominant content,
and low-emphasis connection context. Shared roles and composition take precedence
over equal pixels. This contract is intentionally limited to evidence in the current app.

## Evidence and authority

Read the actual implementation: `app/Packages/TetherFrontend/Sources/TetherUI/Chrome.swift`
(Theme, UIStyle, ChromeButtonStyle), `app/Sources/TetherApp/Design.swift`,
`WorkspaceChrome.swift`, `WorkspaceView.swift`, `Sidebar.swift`, `HostEditor.swift`,
`Palettes.swift`, `SessionView.swift`, `TetherApp.swift`, and the Tmux picker.
`InterfacePreviews.swift` supplies the offline twenty-tab state.
The app icon asset is blue/orange artwork; it does not establish UI accent colors.
The SVGs in `design/compact-zen/final` are generated illustrations, not current Mac
captures: their literal palette and connected-status prose conflict with current code.
They are not token authority. Previous migration/spec/harness notes were not used.

## Shared product rules

| Role | Contract / evidence |
| --- | --- |
| Spacing | 2 tight, 4 small, 6 inline, 8 group, 12 inset, 16 section. Use the role, not a nearby arbitrary number. |
| Text | Compact title 12, supporting detail 11, semibold group header 10, input 13 on desktop. Platform UI font; terminal metrics are independent. |
| Surfaces | Window, chrome/sidebar, raised panel/selection, terminal canvas. Subtle separators, primary and secondary text. Resolve roles through platform appearance and contrast settings. |
| Color meaning | Accent = selection/action; success = connected; warning/danger = exceptional status. Never use accent to mean connected. No branding hex palette is evidenced for chrome. |
| Shapes | Row radius 4, floating-panel radius 10. One-unit separators; two-unit selected-tab accent rule. No rounded card around the terminal. |
| Widths | Tab title cap 180; host picker 280; chooser list maximum height 280. Other evidenced concepts: command panel 420, tree 260; implement only when used. |
| States | Selection is distinct from keyboard focus. Mac custom controls use accent opacity .12 selected, .06 hover, .18 pressed, .45 disabled. These express emphasis, not mandatory Windows compositing formulas. |

Tabs represent named workspaces, with a primary title, optional secondary context,
reserved close affordance and visible selection. Overflow scrolls and selected tabs
remain reachable. Terminal tabs do not need a decorative terminal icon on every tab.
The quick host chooser uses a single-line name with secondary context in a tooltip; host management uses name/address rows. Search precedes results. Native
keyboard activation and dismissal must work. Connection status is quiet when healthy;
exceptions need text or an accessible label, not color alone.

The primary desktop composition is tabs / flexible canvas / host status. Mac uses a
12-unit canvas inset; the Windows canvas is flush with the window, and the selected
tab uses the terminal background so the two read as one surface. Mac uses 36-unit tabs and a 24-unit status bar, minimum 860×520,
default 1100×700. The host control leads; settings trails. A permanent host sidebar
is not the current Mac workspace composition. Inspectors are optional secondary
content (Mac 240–360, ideal 280); zen hides auxiliary chrome. Neither is implemented
by this foundation task.

## Windows adaptation

Use native window caption, snap/resize behavior, Segoe UI, focus visuals, TabView
keyboard selection/overflow/close controls, Flyout light dismissal, ListView and
TextBox behavior, dialogs and system scrollbars. Never copy traffic-light offsets,
AppKit titlebar hooks, SF Symbols or menu-bar conventions. Keep existing Ctrl+N/W.

WinUI resources in `app-windows/Design.xaml` supply the implemented roles. Native
TabView templates retain their state machinery. The selected tab fill is the
terminal canvas brush, and unselected tabs stay transparent on the caption strip.
Status controls have 32-unit minimum height (33 including separator), rather than squeezing Windows controls into 24.
Rows may grow with text scaling; fixed pixel matching is not the acceptance test.
The terminal palette remains independent from chrome appearance.

Only resources and existing native controls are shared. No component registry,
parallel token manifest, generated contract, or framework is needed. Unused tree,
inspector, panel and host-tile concepts are deliberately not implemented yet.

## Inconsistencies and boundaries

- Mac host search uses 12-point title text while UIStyle input is 13; Windows uses
  the explicit input role. Its isolated vertical padding of 5 is not a new token.
- Host management uses body/caption text and a 30×34 tile; compact choosers use
  smaller roles. Do not collapse these different contexts into one universal row.
- Theme comments describe a recessed terminal, but actual colors are dynamic OS
  roles and terminal appearance is independently configurable. Do not canonize a
  specific luminance order for every appearance.
- Windows Add/Manage host buttons previously had empty handlers; this task removes
  these misleading actions, without implementing editing or changing SSH behavior.
- Windows session status is read from its existing model. It does not expose every
  Mac connection stage or a complete status-change notification; live transition
  parity requires a separate model/UI integration decision, not cosmetic inference.
- Native tab curvature and caption height are intentional. Final density judgment,
  icon treatment for empty states, and visual parity need current Mac captures.

## Validation

Build with Visual Studio MSBuild, `app-windows/TetherApp.Windows.csproj /p:Platform=x64`.
Both Visual Studio MSBuild and `dotnet build app-windows/TetherApp.Windows.csproj -p:Platform=x64 --no-restore` pass. No SDK or business-logic changes were made.

Debug executable accepts `--ui-preview` (dark) and `--ui-preview --light`. This uses
the real workspace XAML and native tabs, twenty deterministic labels including a
long final title, disconnected host context, and an empty canvas. It does not load
settings, open terminals, access SSH config or credentials. Client size is 860×520
DIPs after display scaling. Host chooser uses three offline sample hosts and supports filtering to an empty result; settings
and session close actions are inert. Choosing a preview host only changes its displayed label. This is a layout fixture, not a simulated session.

Windows light/dark appearance, selected-tab accent treatment, and host flyout search focus were inspected. Selected-tab reveal now waits for the next render/layout boundary and runs again when the strip resizes, using native ListView.ScrollIntoView. The twenty-tab fixture confirmed the horizontal offset moves from zero to approximately 1503 DIPs. Final screenshot confirmation of overflow remains pending; runtime scroll behavior was verified.

Current Mac captures are unavailable (confirmed by the user). Windows captures can
therefore validate implementation behavior and source-derived composition only;
a controlled cross-platform visual comparison remains pending. For that comparison,
capture the Mac twenty-tab preview at 860×520 in both appearances, with the same
selection and text scale. Compare content bounds, text roles, density and selection,
excluding native caption and glyph rasterization. The Mac preview omits the status
bar and canvas inset; those must be compared against RootView/HostStatusBar separately.

Next: obtain those Mac captures and review this workspace before applying the same
resources to one host chooser/editor flow. Keep full terminal lifecycle, plugins,
settings redesign, zen and inspectors outside that step unless explicitly scoped.

Host chooser copy follows WorkspaceChrome.swift: `Find a host…` and `No matching hosts.` (including an empty host collection). The 280-DIP width includes panel padding. Search supports Up/Down selection and Enter activation; Escape remains native Flyout behavior. Build passed; keyboard interaction still needs manual verification.
