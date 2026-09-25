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

The host renders each workspace plugin as a toolbar and palette entry, and
each tab plugin as an icon on every terminal tab plus a submenu under Terminal.
Inspectors go in the native inspector, settings in Settings → Extensions.
Turning a plugin off closes its tabs and attachments before deactivation.
`TetherPluginKitTests` verifies both shapes independently of tmux;
`app/Plugins/Tmux/Tests` verifies tmux without a server. This interface is a
Swift source API, not a binary ABI or a permission sandbox.

# Using tmux

Open a local shell or connect to a host, then click the tmux icon on the terminal's tab.
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
This initial terminal surface does not yet expose history scrolling or text selection;
it supports keyboard input, native text composition and clipboard paste. tmux's own
copy-mode UI is not emitted over control mode. Alternate-screen, cursor-key and paste
modes are restored; this is not a promise of complete terminal-protocol fidelity for
every existing application state. Default remote socket only; no automatic reconnect.

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
