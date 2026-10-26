# Terminal controls

Windows and macOS expose terminal shortcuts in **Settings → Terminal**. Each
action can be changed independently; invalid or duplicate shortcuts are rejected.
Restore defaults is available in the same pane.

| Action | Windows | macOS |
| --- | --- | --- |
| Copy selection | Ctrl+Shift+C | Cmd+C |
| Paste | Ctrl+Shift+V | Cmd+V |
| Increase font | Ctrl+Shift+Equals | Cmd+Shift+Equals |
| Decrease font | Ctrl+Minus | Cmd+Minus |
| Reset font to 13 | Ctrl+0 | Cmd+0 |

Windows also accepts Ctrl+C when text is selected and Ctrl+V. Without a
selection, Ctrl+C reaches the shell as an interrupt. Right-click exposes Copy
and Paste. Drag across terminal text to select it on either desktop platform.

Font families can be selected from installed fonts: Windows in Settings → Terminal,
macOS in Settings → Appearance. A separate CJK / wide-character family controls
Chinese and other wide glyphs; missing glyphs continue through system fallback.
Windows defaults to Consolas and Microsoft YaHei UI. Font changes apply immediately
and persist. The settings pane includes a mixed-script preview.

Font size is bounded to 10–32 and persists across launches. Windows also exposes
the size in Settings → Terminal; macOS has it in Settings → Appearance.

Multi-line pastes always ask for confirmation. Single-line pastes ask at 4096
UTF-16 code units by default; the threshold is configurable. Cancel sends nothing.
The clipboard payload is captured before asking, then sent as a semantic paste
so the terminal engine can honor bracketed-paste mode.

The status bar distinguishes `Exited (0)`, other exit codes, `Closed`, and
`Connection lost`. Hovering a connection failure exposes its cause. Final output
remains visible and copyable after exit.

On macOS and iOS, Files follows the active tmux pane's working directory while
the browser is visible, checking once per second. Pane and window switches made
through tmux's own controls are included. Manual browsing stays put until the
terminal reports a different directory; the Shell control returns to the current
pane immediately.

Printed file paths resolve relative to the pane containing the link, including
inactive panes. Cmd-click on macOS previews the file; its context menu offers
Quick Look, Show in Files, Edit, and Download…. A folder downloads with its
contents. Edit opens a local copy with the default app and writes saved changes
back to the host. On iOS, long-press offers the preview, Show in Files, and
Download….

## Verification

On Windows:

```powershell
dotnet run --project tests/terminal-experience
dotnet build app-win/TetherApp.Windows.csproj -p:Platform=x64
```

For distribution, run `./scripts/publish-windows.ps1`. It builds the release
native library and publishes a self-contained, compressed single EXE using
`app-win/Properties/PublishProfiles/Portable.pubxml`. The ZIP is written to
`artifacts/windows-portable/Tether-win-x64.zip`; CI uploads the same archive.
Debug symbols and SDK XML documentation are omitted. The executable extracts
its bundled runtime on first launch. Debug builds keep their normal layout.
Trimming is disabled to preserve WinUI and reflection-based serialization.

On macOS:

```sh
swift test --package-path app/Packages/TetherFrontend --filter TerminalExperience
swift test --package-path app
```

Manual checks: remap and restore each shortcut; zoom without inserting a stray
character at the prompt; copy forward and backward selections including CJK and
combining characters; cancel and accept a multi-line paste; switch tabs while a
paste confirmation is open; run `exit 0` and `exit 7`; disconnect an SSH transport.

### Native terminal presentation

Apple's Appearance settings now separate terminal light/dark appearance from
ANSI color style. Soft is the app default, matching the Windows frontend's
existing softer palette; Classic preserves the original colors. Named ANSI
slots keep their meaning, and explicit RGB output is untouched. The palette
used for the selected tab, terminal background and remote color-query responses
is the same. Both soft variants participate in the existing contrast checks;
Soft Light's dim gray was adjusted on both platforms to meet the text floor.

Terminal padding is adjustable from 0 to 40 points and defaults to 16 on Mac and Windows,
12 on iPhone/iPad. Changing it refits the PTY and updates input/selection geometry.
A consumer's explicit TerminalSurface inset still takes precedence. Font choices
and sizes remain the person's own preferences, with native system monospace as
the existing default. SDK callers of Palette.chosen that omit the new style
argument keep the original classic-palette contract.

### Windows workspace layout

The default tab strip stays at the top, sharing one 32-DIP titlebar row with
Windows' native caption buttons. Tab chips have a terminal mark, single-line
title/caption, a 12% accent selection fill and a 2-DIP selection rule. Native
TabView still owns focus, keyboard navigation, selection and close requests;
close-button space is reserved and the mark appears on hover or selection.
The former titlebar menu/toggle toolbar and persistent split toolbar are hidden.
The workspace menu remains on the host bar's context menu and commands stay in
the command palette and tab context menus.

The host bar is 24 DIPs: current host and state at the leading edge, inspector
plugins and Settings at the trailing edge. State descriptions live in tooltips
and accessibility labels. Terminal padding is applied once by TerminalControl;
the outer canvas adds none. A single pane has no surrounding accent frame;
split focus uses the same top-edge marker as macOS. Default client size is
1100×700 DIPs, limited to the monitor work area. Inspector width defaults to 280
(240–480 range); the optional vertical tab sidebar remains an explicit preference,
220 DIPs wide with a 180–320 resize range. Existing preferences are retained.

`tests/windows-layout` links the actual MainWindow.xaml, Design.xaml and native
appearance observer into a standalone WinUI app with inert actions and static
text. It opens no shell, engine, SSH or user settings. Compilation runs in the
Windows gate; desktop inspection runs manually. Launch its executable with no
arguments for top tabs, `--light` for light appearance, `--overflow --narrow` for
20 tabs at 760 DIPs, or `--empty` for an empty workspace. It records geometry and
native setting-notification assertions in its own bin directory and closes after
60 seconds. Inspect and close only this fixture during UI automation.

The normal single-file Release executable must also be launched after publishing.
A window handle, a responsive message loop and absence of an immediate crash
are required startup evidence. The earlier render-only fixture did not register
the window's appearance observer and therefore missed a CoreWindow-dependent
event registration failure. WindowEffects now listens to native setting/theme/
system-color messages after WinUI's initial layout and removes the subclass on
close. This keeps CoreWindow-only WinRT event subscriptions out of desktop startup.

### Windows Quick Terminal

Quick Terminal presents the same WinUI window and terminal workspaces at the top
of the monitor under the pointer. The native work area excludes the taskbar;
negative monitor origins and the current DPI are retained. Ctrl+Backquote is the
default global shortcut; both configurable slots use RegisterHotKey with repeat
suppression. A registration conflict leaves the menu/command-palette entry usable
and appears in Settings → Quick Terminal and after applying Key Bindings.

Repeated toggling hides/reveals the HWND without closing sessions. Auto-hide is
optional; owned settings/authentication windows stay above the terminal. Restore
Window restores ordinary position/size/maximized state and the independent
Keep Window on Top preference. Closing Quick Terminal with the caption button or
Alt+F4 hides it; Quit Tether from its notification-area menu follows the existing
window-close confirmation. The existing quit-on-last-tab preference is retained.
No shortcut or tray registration remains after the main window closes. The icon
is re-added when Explorer sends TaskbarCreated.

The legacy settings file receives enabled/auto-hide/tray defaults and normal
window topmost defaults to off. Shortcut validation and geometry/settings
regressions run with `tests/terminal-experience` in the ordinary Windows checks.
The separate desktop-only smoke test uses Forms as a native HWND fixture, without
opening a shell, modifying the person's preferences or injecting keyboard text:

```powershell
dotnet run --project tests/quick-terminal -- --interactive
# Click Run native checks in the fixture window.
```

It verifies real OS shortcut registration conflicts, primary/secondary rebinding
and release, WM_HOTKEY routing, repeated hiding/reopening, owned-window handling,
normal/maximized/minimized restoration, and Explorer tray-icon add/remove and
callback routing. Interactive checks are not run in CI. They post native hotkey
messages to verify routing; physical keyboard layouts, Explorer restart and
actual cross-monitor DPI transitions still need manual platform QA.

The native owner check follows [GW_OWNER](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getparent)
explicitly, since GetParent/GA_ROOTOWNER can miss owned overlapped windows.
