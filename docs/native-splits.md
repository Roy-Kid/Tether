# Windows native terminal workspaces

Windows tabs own a recursive split tree. Each leaf owns an independent
terminal session, renderer, history and plugin attachments. Splitting inherits
the focused pane's host and known directory; it does not clone a running program.
Local Windows panes also inherit the shell profile and WSL distribution.

| Action | Windows default |
| --- | --- |
| Left/right split | Ctrl+Shift+D |
| Top/bottom split | Ctrl+Shift+E |
| Directional focus | Alt+Shift+Arrow |
| Maximize/restore pane | Ctrl+Shift+Enter |
| Close focused pane | Ctrl+Shift+W |
| Close entire tab | Command menu |

All shortcuts are configurable. The status bar also has icon-only split and
maximize controls with accessible names and tooltips. Dividers retain their
ratios when switching tabs. Maximizing leaves the other sessions running.

Host switching affects the focused pane. Files, plugin commands and connection
status follow pane focus.

Closing a pane folds its empty split branch. Closing a tab checks all panes and
asks once about running work. Recent closes and open workspaces survive restart,
but reconnect only through the existing Restore Tab action. A restored pane
returns beside its surviving neighbor; if the original workspace is gone it
opens in a new tab. Saved layouts contain no passwords. Host security settings
are checked against current configuration before reconnecting.

History manifest version 2 reads version 1 single-terminal records. It retains
every pane's history and rejects corrupt trees without deleting archives.
Apple keeps the current master workspace implementation (`WorkspaceSplit.swift`);
its layout model and shortcuts are independent of these Windows details.

On Apple platforms, Split Left, Split Right, Split Up and Split Down place a
new shell beside the focused terminal within the current tab. Each pane can be
split again. The new shell receives focus; closing a pane folds its branch
without closing its neighbors. Four-way layouts are saved and restored with
the workspace. Mac dividers remain natively resizable.

The commands are available in the Terminal menu, command palette and tab context
menu, and on Mac in the terminal context menu. Right-clicking a background tab
splits that tab's focused terminal. Split Right keeps ⌘\ and Split Down keeps
⇧⌘\; Left and Up can be assigned in Key Bindings. iPad exposes all four
directions in its Commands menu when there is room; compact windows disable
splitting.

The shared commit/CI gate runs Windows builds, native regressions and portable
publication, plus Swift tests and an unsigned iOS simulator build on macOS.
Interactive platform QA should cover high DPI, Chinese text, selection, mouse
reporting, divider dragging and modal dialogs across multiple panes.
