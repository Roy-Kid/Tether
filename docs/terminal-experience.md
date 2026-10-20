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
Quick Look, Show in Files, Edit, and Download. Edit opens a local copy with the
default app and writes saved changes back to the host. On iOS, long-press offers
the preview, Show in Files, and Download.

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

Terminal padding is adjustable from 0 to 40 points and defaults to 16 on Mac,
12 on iPhone/iPad. Changing it refits the PTY and updates input/selection geometry.
A consumer's explicit TerminalSurface inset still takes precedence. Font choices
and sizes remain the person's own preferences, with native system monospace as
the existing default. SDK callers of Palette.chosen that omit the new style
argument keep the original classic-palette contract.
