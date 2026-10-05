# Windows parity with macOS

Baseline: `origin/master` at `e7c8cb6`, merged into `windows-app`.

Windows now provides configurable workspace and plugin shortcuts, a searchable
command palette and quick switcher, horizontal or vertical tabs, zen mode,
tab renaming, and restoration of closed tabs and previous-launch tabs. Terminal
history uses the shared SQLite archive with configurable retention. Restoration
uses current SSH configuration and refuses changed or removed destinations.

The Windows SDK now exposes session history, encrypted-key passphrase prompts,
skipped-key diagnostics, terminal mouse reporting, working directory and terminal
identity, bounded command execution, and tmux session management. The Windows
tmux inspector supports remote sessions, windows, split panes, zoom, and detach;
its commands participate in the shared command palette and shortcut settings.

Closing tabs or the window checks shell activity. File browsing adds bounded text
previews, large-download confirmation, and download-directory preferences. Binary
previews use the operating system's registered viewer. ConPTY exit now releases
the master handle so the final output drains and history checkpoints complete.

## Remaining platform differences

- Apple's CloudKit/iCloud synchronization, Secure Enclave identity management,
  device authorization, and cross-device continuity have no Windows service
  implementation here. Windows does not yet provide the macOS identity editor.
- Host management currently edits and validates OpenSSH configuration rather
  than providing the macOS structured host editor and import workflow.
- The tmux inspector requires an SSH host; local WSL tmux is not integrated.
- Native Quick Look previews and macOS file-cache/tree performance behavior are
  not fully reproduced by Windows text/external-viewer previews.
- The upstream WebPluginHost package is not yet integrated into either desktop
  application; it is not represented as a working Windows feature.

Windows compilation and shared/native regression tests are exercised locally.
macOS/Swift compilation and interactive Windows UI testing still require their
respective runtime environments. This change establishes common workflow parity,
but does not claim complete parity for the differences above.
