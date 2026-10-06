# Native terminal workspaces

Windows and macOS tabs own a recursive split tree. Each leaf owns an independent
terminal session, renderer, history and plugin attachments. Splitting inherits
the focused pane's host and known directory; it does not clone a running program.
Local Windows panes also inherit the shell profile and WSL distribution.

| Action | Windows default | macOS default |
| --- | --- | --- |
| Left/right split | Ctrl+Shift+D | Command+D |
| Top/bottom split | Ctrl+Shift+E | Command+Shift+D |
| Directional focus | Alt+Shift+Arrow | Command+Shift+Arrow |
| Maximize/restore pane | Ctrl+Shift+Enter | Command+Shift+Return |
| Close focused pane | Ctrl+Shift+W | Command+W |
| Close entire tab | Command menu | Command+Shift+W |

All shortcuts are configurable. The status bar also has icon-only split and
maximize controls with accessible names and tooltips. Dividers retain their
ratios when switching tabs. Maximizing leaves the other sessions running.

Host switching affects the focused pane. Files, plugin commands and connection
status follow pane focus. macOS groups a workspace under its original host,
including when another pane connects to a different host.

Closing a pane folds its empty split branch. Closing a tab checks all panes and
asks once about running work. Recent closes and open workspaces survive restart,
but reconnect only through the existing Restore Tab action. A restored pane
returns beside its surviving neighbor; if the original workspace is gone it
opens in a new tab. Saved layouts contain no passwords. Host security settings
are checked against current configuration before reconnecting.

History manifest version 2 reads version 1 single-terminal records. It retains
every pane's history and rejects corrupt trees without deleting archives.
iOS exposes no split controls or shortcuts; multi-pane archives restore as
individual terminal tabs there.

The shared commit/CI gate runs Windows builds, native regressions and portable
publication, plus Swift tests and an unsigned iOS simulator build on macOS.
Interactive platform QA should cover high DPI, Chinese text, selection, mouse
reporting, divider dragging and modal dialogs across multiple panes.
