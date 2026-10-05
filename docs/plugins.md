# Frontend extensions

Built-in extensions are compiled into the app. A plugin is an independent
Swift package depending on `TetherPluginKit`; import `TetherUI` for a terminal
surface and for the window's chrome vocabulary (`Theme`, `UIStyle`,
`ChromeButtonStyle`), so what a plugin draws matches what the window draws.
Built-in plugins live in `app/Plugins/`; `app/Plugins/Tmux` is the working
example, and the app reaches it only through the kit.

Software installed after shipment is a different host. See [Web plugin host](#web-plugin-host).

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

Settings → Appearance → Tab Layout switches between the horizontal titlebar
and a vertical tab list on the left. The layout is saved across launches.
Cmd+S shows or hides the entire tab bar in either layout, without closing any
sessions. The titlebar button and View → Show/Hide Tab Bar do the same thing.
Visibility is saved locally and restored on the next launch in either layout.
Zen temporarily hides the bar without changing this preference.
Customize the shortcut under **Toggle Tab Bar** in Settings → Key Bindings.
The same **Toggle Tab Bar** command is available in the Cmd+Shift+P command menu,
whether the tab bar is currently shown or hidden.
Showing tabs from Zen Mode exits Zen Mode; opening a tab's accessory also
reveals a hidden tab bar so its popover has a visible anchor.

Settings → Key Bindings lists workspace and plugin commands, including commands
without a default shortcut. Search by command, group or shortcut, or toggle grouping
with the button beside the search field. Both controls stay visible while scrolling.
Each command has independent Primary and
Secondary shortcuts; either runs the same action. Click a slot and press a
combination of ⌃, ⌥, ⇧ and ⌘ with a key, or a function key.
macOS displays these modifier symbols throughout shortcut settings, menus and
tooltips. Search also accepts modifier names such as `ctrl`, `option` and `cmd`.
Esc cancels recording. Consecutive key sequences are not supported.

Changes apply immediately and persist locally across launches. With an iCloud-enabled
signed build, custom bindings sync through the existing iCloud account and **Sync Now**
action. Offline edits are queued; incoming changes update shortcuts and menus without
restarting. Clear a slot with
its × button; reset a modified row to restore its defaults. Duplicate bindings
are rejected across both slots and all known commands, including disabled plugins.
The menu shows the first assigned shortcut; the command palette shows both.

Closing a terminal checks its processes. An idle shell or ended session closes
without confirmation; foreground, background and stopped jobs prompt before
closing, with the process names and a warning about interrupted work. If the
process check fails, times out or cannot identify the remote terminal, closing
still asks and explains that the process state is unknown. Active file transfers
also require confirmation; a tmux attachment that only detaches does not.
Plugins report interruptible work through `requiresCloseConfirmation` and describe
the consequences in `closeNote`.

The close-tab confirmation accepts Enter (including keypad Enter) or Cmd+W to
close the tab. Escape cancels. Holding a confirmation key does not count as a
second press; these shortcuts apply only while that confirmation is visible.

Sync stores one record per command in the private `TetherKeyBindings` zone
(`TetherKeyBinding`, with a `value` Bytes field). Both alternatives travel together.
Different commands merge independently; concurrent edits to the same command use
the later recorded modification time, with a stable revision identifier breaking ties.
Clearing a slot and restoring defaults are distinct: resets remain as records so an
offline device cannot resurrect an older assignment. A fresh installation uploads
no defaults. Existing local overrides migrate once into the first signed-in account;
an existing cloud revision of the same command takes precedence over a legacy
override without an edit time. Each Apple account keeps a separate offline cache.
Signing out switches to local settings; cloud settings never move to another account.
The first sync after upgrading reads the account in full, even when an older
app has already advanced the CloudKit change token past key binding records.

Concurrent edits to different commands can assign the same combination. Explicit
assignments take precedence over defaults, then the newer command revision wins.
The losing assignment is retained and shown in orange with a hover explanation,
but does not dispatch or appear as an active menu shortcut. Reassign or clear it
to resolve the conflict. Assignments for unavailable plugins are retained as well.

Ad-hoc builds remain local and show the existing iCloud-unavailable status. Real
sync needs the same developer team, container entitlement and provisioning setup
as host sync (`./scripts/tether.sh --provision --team <TEAMID>`, then
`./scripts/tether.sh --build-app --team <TEAMID>`). Development builds can create
the record type in the development database; deploy the new record type and its
field to the container's production schema before shipping an App Store build.
Validate on two devices signed into the same Apple account: edit different
commands offline, reconnect, clear/reset a binding, and verify both devices agree.

Assigned combinations take priority over terminal input in the workspace window.
Unbound Ctrl/Alt keys still reach the shell or remote editor. Sheets, Settings and
input-method composition retain their own keyboard handling. Plugin actions run
only when provided by the selected tab's current attachment or workspace. Native
text editing, file-list navigation and dialog confirmation keys keep their normal
context-specific behavior; this page configures workspace commands.

New Terminal defaults to Cmd+N (primary) and Cmd+T (secondary). These take
priority over terminal input in the workspace; personal overrides remain unchanged.
**Restore Tab** defaults to Cmd+Shift+T and is available in File, the command menu
and Key Bindings. Each press reopens the most recently closed terminal, selecting
its original host and restoring its name and position. The last 20 closed
terminals are remembered for the current app run; cancelling a password prompt
keeps the entry available. The action is disabled when history is empty.
Local shells reopen in their previous directory when it still exists. SSH uses
the usual authentication flow and opens a fresh shell. Closed processes and shell
scrollback cannot be recovered. tmux attachments reconnect to the previous session
if it still exists, and Files restores its browser directory. Active transfers
are not restarted. Quitting or switching accounts clears this history.
Tab plugins can implement `restorationState` and `restore(from:)` to save
nonsecret metadata and apply it to a new attachment after authentication.
Rename Terminal defaults to Cmd+R and renames the selected terminal.
In its dialog, Return or keypad Enter saves the name; Escape cancels.
Common Unix Control keys, including Ctrl+N/T, and Alt+B/F/D remain available to the terminal.
Unassigned Control letters are sent unchanged as control input;
the shell or editor decides what they do, including when cursor-key mode changes.
The command palette, Quick Switch and host picker accept Ctrl+P/N as Up/Down.
On macOS, these popups and the tmux session/window picker also show Cmd+1 through
Cmd+9 beside their first nine available items. Pressing a number with Cmd immediately
activates that item; filtering or entering a submenu updates the numbers. Disabled
items are skipped. While a popup is open, these keys take priority over workspace
bindings; closing it restores the usual bindings.
Their search fields keep native Ctrl+B/F character movement and Ctrl+A/E
beginning/end movement. The file tree accepts Ctrl+P/N to select rows and
Ctrl+B/F as Left/Right to collapse/expand folders or move to their parent/first
child. Except for a popup's numbered shortcuts, custom workspace bindings still
take priority when explicitly assigned.

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

# Web plugin host

`app/Packages/TetherPluginHost` installs web software beside the built-in
plugins. A package is a manifest plus HTML, CSS, and JavaScript. Install
registers contributions and does not run the page. Activation loads the
page in an isolated WebKit view. The page reaches the app through the
capability API (`document.read`, `storage.plugin`, `host.notify`). The host
rejects native binaries, dynamic libraries, and install scripts. The
canonical note is `.claude/notes/web-plugin-host.md`.

Built-in plugins do not go through this host, and this host does not name
them. Nothing here is wired into the window yet.

# Using tmux

Open a local shell or connect to a host, then right-click the terminal's tab and choose tmux sessions. Clicking the selected tab opens the same picker.
The machine running that shell must have `tmux` on its command path. Select an existing
session or name a new one. The session is attached in that same terminal: tmux draws
its own windows, panes and status line. The plugin does not replace the terminal.

The picker and the Terminal menu create windows, split the current pane and zoom it.
Window and session menus rename or end them. Detach, or the shell row, leaves tmux
and returns to the prompt. Choosing the session this terminal is already in stays there.
The wheel on that client is given to tmux, so tmux's own history moves and the
status line stays where it is. The next key returns to the live prompt.
Closing the tab detaches only. Ending remote tasks is a separate confirmed action.
Missing tmux, rejected commands and connection errors are shown in the picker.
Ordinary SSH remains available when tmux is disabled. Default remote socket only.

# Verification

Use latest stable Rust (`rustup update stable`) and Xcode with Swift 6.2 or later.

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
./scripts/tether.sh --build-xcframework
swift test --package-path swift
swift test --package-path app/Packages/TetherFrontend
swift test --package-path app/Packages/TetherPluginHost
swift test --package-path app/Plugins/Tmux
./scripts/tether.sh --build-app
```

Debug builds support `TETHER_HOSTS_FILE=/absolute/path/hosts.json` for isolated UI
fixtures. This does not change the normal host store and is absent from release builds.
