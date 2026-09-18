# Frontend extensions

Tether's macOS frontend loads extensions at compile time. A plugin is an independent
Swift package depending on `TetherPluginKit`; import `TetherUI` when it needs a
terminal surface. `app/Packages/TmuxPlugin` is the working example.

1. Implement `TetherPlugin` with a stable `PluginMetadata.id`, lifecycle methods,
   `launch(in:)` and optional `settings()`.
2. Implement `PluginWorkspace`: a UUID, title/subtitle/icon, content, inspector,
   commands and idempotent `close()`. Keep observable workspace state in your module.
3. Use `PluginContext.openWorkspace` to give the host ownership of a new tab.
   Use its connection for SDK operations and its reconnect closure when fresh
   authentication is required. Do not store credentials.
4. Add the package product to the application's dependencies and register your
   plugin in the application composition root. No RootView switch is needed.
5. Release subscriptions, cancel operations and detach remote resources in `close()`.
   Store nonsecret preferences with `PluginPreferences(pluginID:)`.

The host renders each registered plugin as a navigation/toolbar entry, its commands
in the workspace toolbar, its inspector in the native inspector, and its settings
in Settings → Extensions. Disablement closes all matching tabs before deactivation.
The example test plugin in `TetherPluginKitTests` verifies this lifecycle independently
of tmux. This interface is a Swift source API, not a binary ABI or a permission sandbox.

# Using tmux

Connect to a host, then click tmux in the toolbar or sidebar. The remote host must
have `tmux` on the SSH command's PATH. Select an existing session or name a new one.
The toolbar creates windows, splits panes and toggles pane zoom. Click a pane to
focus it; drag its borders to resize. Window context menus rename or end windows.
The inspector exposes active-pane actions. Session context menus in the picker
rename or end sessions.

Closing the workspace tab detaches only. Ending remote tasks is a separate confirmed
action. After a connection loss, Reconnect requests authentication and attaches the
previous session if it still exists. Missing tmux, rejected commands and connection
errors are shown in the workspace. Ordinary SSH remains available when tmux is disabled.

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
bash scripts/build-xcframework.sh
swift test --package-path swift
bash scripts/test-native-tmux.sh # loopback OpenSSH + real tmux end-to-end
swift test --package-path app/Packages/TetherFrontend
bash scripts/build-app.sh
```

Debug builds support `TETHER_HOSTS_FILE=/absolute/path/hosts.json` for isolated UI
fixtures. This does not change the normal host store and is absent from release builds.
