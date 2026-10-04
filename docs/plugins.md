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

The host renders each workspace plugin as a toolbar and palette entry.
A tab plugin kept beside the terminal is a button at the bottom right of
the window, next to Settings; one that opens a picker is an item on the tab's menu. Both
also have a submenu under Terminal.
Inspectors go in the native inspector, settings in Settings → Extensions.
Turning a plugin off closes its tabs and attachments before deactivation.
`TetherPluginKitTests` verifies both shapes independently of tmux;
`app/Plugins/Tmux/Tests` verifies tmux without a server. This interface is a
Swift source API, not a binary ABI or a permission sandbox.

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
