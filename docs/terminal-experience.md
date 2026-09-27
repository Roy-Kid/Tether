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

## Verification

On Windows:

```powershell
dotnet run --project tests/terminal-experience
dotnet build app-windows/TetherApp.Windows.csproj -p:Platform=x64
```

On macOS:

```sh
swift test --package-path app/Packages/TetherFrontend --filter TerminalExperience
swift test --package-path app
```

Manual checks: remap and restore each shortcut; zoom without inserting a stray
character at the prompt; copy forward and backward selections including CJK and
combining characters; cancel and accept a multi-line paste; switch tabs while a
paste confirmation is open; run `exit 0` and `exit 7`; disconnect an SSH transport.
