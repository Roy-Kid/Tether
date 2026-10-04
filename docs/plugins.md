# Frontend extensions

Tether's frontend loads extensions at compile time. A plugin is an independent
Swift package depending on `TetherPluginKit`; import `TetherUI` for a terminal
surface and for the window's chrome vocabulary (`Theme`, `UIStyle`,
`ChromeButtonStyle`), so what a plugin draws matches what the window draws.
Built-in plugins live in `app/Plugins/`; `app/Plugins/Tmux` is the working
example, and the app reaches it only through the kit.

A plugin takes one of two shapes.

**A workspace plugin** is a tab of its own.

1. Implement `TetherPlugin` with a stable `PluginMetadata.id`, lifecycle methods,
   `launch(in:)` and optional `settings()`.
2. Implement `PluginWorkspace`: a UUID, title/subtitle/icon, content, inspector,
   commands and idempotent `close()`. Keep observable workspace state in your module.
3. Use `PluginContext.openWorkspace` to give the host ownership of a new tab.
   Use its connection for SDK operations and its reconnect closure when fresh
   authentication is required. Do not store credentials.

**A tab plugin** lives inside a terminal tab the person already has.

1. Implement `TabPlugin`: a `TabAccessory` (a symbol, and the name its tooltip
   and menu item use) and `attach(to:)`, called once per tab the first time
   the accessory opens there.
2. Return a `TabAttachment`. It reports whether it stands in for the shell, the
   subtitle beside the tab's name, whether it is disconnected, a note for the
   close confirmation, and its commands. It supplies content, an inspector and
   what opens behind the accessory, and it releases everything in `close()`.
3. Use `TabContext` for what only the host can do: focus the tab, dismiss the
   accessory, present a sheet. Anything that spans tabs belongs to the
   plugin, which is the one party that knows every tab it is attached to.

For either shape:

- Add the package product to the application's dependencies and register the
  plugin in the application's composition root. That line is the only place
  the app may name it; CI fails on any other.
- Store nonsecret preferences with `PluginPreferences(pluginID:)`.
- Expose stable `commandDescriptors` on the plugin for commands that should
  appear in Settings → Key Bindings before connecting. Their IDs must match
  the commands returned by attachments or workspaces. The host namespaces IDs
  by plugin and dispatches against the selected tab's current commands.

The host renders each workspace plugin as a toolbar and palette entry.
A tab plugin kept beside the terminal is a button at the bottom right of
the window, next to Settings; one that opens a picker is an item on the tab's menu. Both
also have a submenu under Terminal.
Inspectors go in the native inspector, settings in Settings → Extensions.
Turning a plugin off closes its tabs and attachments before deactivation.
`TetherPluginKitTests` verifies both shapes independently of tmux;
`app/Plugins/Tmux/Tests` verifies tmux without a server. This interface is a
Swift source API, not a binary ABI or a permission sandbox.

# Key bindings (macOS)

Settings → Key Bindings lists workspace and plugin commands, including commands
without a default shortcut. Search by command, group or shortcut, or toggle grouping
with the button beside the search field. Both controls stay visible while scrolling.
Each command has independent Primary and
Secondary shortcuts; either runs the same action. Click a slot and press a
combination of Ctrl, Alt (Option), Shift and Command with a key, or a function key.
Esc cancels recording. Consecutive key sequences are not supported.

Changes apply immediately and persist locally across launches. Clear a slot with
its × button; reset a modified row to restore its defaults. Duplicate bindings
are rejected across both slots and all known commands, including disabled plugins.
The menu shows the first assigned shortcut; the command palette shows both.

Assigned combinations take priority over terminal input in the workspace window.
Unbound Ctrl/Alt keys still reach the shell or remote editor. Sheets, Settings and
input-method composition retain their own keyboard handling. Plugin actions run
only when provided by the selected tab's current attachment or workspace. Native
text editing, file-list navigation and dialog confirmation keys keep their normal
context-specific behavior; this page configures workspace commands.

Defaults leave Ctrl+P/N/F/B, other common Unix Control keys and Alt+B/F/D
available to the terminal. Control letters are sent unchanged as control input;
the shell or editor decides what they do, including when cursor-key mode changes.
The command palette, Quick Switch and host picker accept Ctrl+P/N as Up/Down.
Their search fields keep native Ctrl+B/F character movement and Ctrl+A/E
beginning/end movement. The file tree accepts Ctrl+P/N to select rows and
Ctrl+B/F as Left/Right to collapse/expand folders or move to their parent/first
child. Custom workspace
bindings still take priority when explicitly assigned.

Common operations follow the focused control. Native text fields in the workspace,
Settings, sheets and popovers use AppKit editing, with these additional Unix-style
aliases; no system-wide key binding preferences are changed:

| Operation | Keys |
| --- | --- |
| Character / line movement | Ctrl+B/F, Ctrl+A/E |
| Word movement / word selection | Alt+B/F, Alt+Shift+B/F |
| Character deletion | Ctrl+H/D, Backspace / Delete |
| Word deletion | Ctrl+W / Alt+Backspace backward, Alt+D forward |
| Delete to beginning / end | Ctrl+U / Ctrl+K |
| Yank deleted text / transpose characters | Ctrl+Y / Ctrl+T |
| Undo / redo | Ctrl+_ or Cmd+Z / Cmd+Shift+Z |
| Select text | Shift+arrows; Ctrl+Shift+B/F/A/E |
| Select all / cut / copy / paste | Cmd+A/X/C/V |
| Confirm / cancel | Return or Ctrl+M/J / Escape or Ctrl+G |
| Next / previous field | Tab or Ctrl+I / Shift+Tab |

Command, host, settings, file and session lists support Up/Down or Ctrl+P/N,
Page Up/Down or Alt+V/Ctrl+V, and Home/End or `Alt+<` / `Alt+>`. Selection stays within
available items; Shift+arrows remain available for native text or multi-row
selection. File and session trees also accept Ctrl+B/F as Left/Right. Return keeps
the control's existing action (for example, rename in the file list). Escape and
Ctrl+G cancel pickers; in a session submenu they first return to the parent level.

These are common single-key editing aliases, not a complete Emacs implementation:
there is no prefix-key sequence, universal argument or application-side mark ring.
Ctrl+U uses line-editing behavior. The terminal receives original Control/Alt input,
so history search (Ctrl+R), job control (Ctrl+C/D/Z), completion, marks and editor
commands remain the shell/editor's responsibility. Input-method composition and
shortcut recording keep their own keyboard handling. This settings page still
configures workspace commands; context-specific editing/list keys are defaults.

# Using tmux

Open a local shell or connect to a host, then right-click the terminal's tab and choose tmux sessions. Clicking the selected tab opens the same picker.
The machine running that shell must have `tmux` on its command path. Select an existing
session or name a new one.
The toolbar creates windows, splits panes and toggles pane zoom. Click a pane to
focus it; drag its borders to resize. Window context menus rename or end windows.
The inspector exposes active-pane actions. Session context menus in the picker
rename or end sessions.

The shell row (labelled with the local shell name when known) returns to the tab's
original terminal. If that terminal is itself attached to a tmux session, the picker
marks that session and returns to the existing client instead of opening a second one.
Closing the tab detaches only. Ending remote tasks is a separate confirmed action.
After a connection loss, Reconnect requests authentication and attaches the previous
session if it still exists. Missing tmux, rejected commands and connection errors are
shown in the picker or workspace. Ordinary SSH remains available when tmux is disabled.

Native frames restore existing screen content and a bounded history on attach.
The wheel scrolls that history. A drag selects text, highlights it, and copies it;
⌘C copies the selection again. Keyboard input, native text composition and clipboard
paste work as well. tmux's own copy-mode UI is not emitted over control mode.
Alternate-screen, cursor-key and paste modes are restored; this is not a promise of
complete terminal-protocol fidelity for every existing application state. Default
remote socket only; no automatic reconnect.

# Verification

Use latest stable Rust (`rustup update stable`) and Xcode with Swift 6.2 or later.
Install tmux locally to run its integration tests.

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
./scripts/tether.sh --build-xcframework
swift test --package-path swift
./scripts/tether.sh --test-tmux # loopback OpenSSH + real tmux end-to-end
swift test --package-path app/Packages/TetherFrontend
swift test --package-path app/Plugins/Tmux
./scripts/tether.sh --build-app
```

Debug builds support `TETHER_HOSTS_FILE=/absolute/path/hosts.json` for isolated UI
fixtures. This does not change the normal host store and is absent from release builds.
