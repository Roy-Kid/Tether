# Native frontend modules and tmux workspaces

Date: 2026-09-17
Status: accepted

The macOS application needs independent extensions without teaching its root
view about each feature. The first extension is a native tmux workspace.

## Boundaries

`TetherFrontend` exports `TetherPluginKit` and `TetherUI`. The former describes
plugin metadata, lifecycle, workspace content, inspector content, commands,
and settings. The latter owns the shared terminal surface, palette, metrics,
and AppKit keyboard/input-method bridge. `TmuxPlugin` is an independent Swift
package. Registering another package is the only application composition change
required to introduce another extension. Plugins are compiled in, not downloaded
or dynamically loaded. This is a composition boundary, not a security sandbox.

The application owns tabs, focus, connection prompts, and plugin enablement.
A plugin receives an authenticated connection lease, not credentials. Disabling
an extension closes its workspaces before calling its deactivation hook.
Preferences are namespaced; passwords and keys are never plugin preferences.

`tether-tmux` consumes an abstract ordered duplex byte stream. It imports neither
SSH nor a UI toolkit. It composes tmuxctl 0.1.0's protocol parser with the existing
tether-terminal engine, one engine per pane. The SSH channel adapter lives at the
FFI composition boundary. Generated types stay behind the Swift facade.

## Dependency decision

The official tmux control protocol is the transport. tmuxctl supplies a sans-I/O
parser, binary-safe pane output decoding, typed notifications and layout parsing.
Its default process driver is disabled. This fits remote streams and avoids
embedding a second terminal engine. tmux_interface/libtmux's subprocess-oriented
APIs do not fit this transport; par-term's terminal stack duplicates our engine.
The dependency is young, so it is version-pinned and covered by real-tmux tests,
fragmented stream tests, and bounded input handling. Its public types never cross
our component boundary. No VT or SSH parser is reimplemented.

At the user's explicit request, builds use the latest Rust stable channel.
The verified stable release is 1.98.1; Cargo's minimum is raised to that version,
`rust-toolchain.toml` selects stable, and CI updates stable. This deliberately
trades a compiler pin for following stable releases. Apple deployment targets
remain 26.0 and are explicit when compiling native dependencies.

## Lifetime and failure behavior

A shell and tmux control channels share one authenticated SSH connection through
reference-counted leases. Closing a channel does not terminate other channels.
The existing terminal-connect entry point remains available.

Opening tmux is an explicit action after connecting an ordinary SSH shell.
Choosing an existing session attaches; creating a session is a distinct action.
Closing a workspace detaches, preserving remote jobs. Ending panes, windows, or
sessions is explicit and confirmed. A lost connection retains the last frame;
recovery is manual and may request fresh credentials. If the remote session is
gone, the picker returns rather than creating a replacement silently.

All commands are serialized with their replies. Remote layout and active-pane
metadata are authoritative. Initial screen capture is ordered with pane output;
terminal modes are restored on attach. Input queues, line/response sizes, layout
nesting, pane count, visible cells and history have limits. A response timeout
ends the control stream because subsequent replies can no longer be correlated
safely. These limits produce visible errors rather than unbounded allocation.

The baseline supports the remote default tmux socket. Automatic reconnect,
local terminal sessions, arbitrary-shell control-mode interception, and a plugin
marketplace remain outside this change.
