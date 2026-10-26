# Tether

Components an application imports to embed a working SSH terminal.

The ecosystem has excellent terminal *applications* and excellent terminal
*engine crates*. It does not have the layer between them: a componentised,
embeddable, customisable SSH terminal with a stable API that an app developer
drops in and wires to their own UI.

That layer is Tether. Its value is composition, boundaries and API — not engine
internals. SSH comes from `russh`, terminal emulation from
`alacritty_terminal`, cryptography from `aws-lc-rs`; what Tether owns is the
lifecycle that binds them, the errors a consumer sees, and an API that stays
stable while the pieces underneath are replaced.

Two products live here: **the SDK**, which is the primary product, and **the
app**, a standalone terminal client and the first consumer of that SDK.

## Components

```text
tether-terminal    bytes → screen state + damage; input encoding
tether-ssh         transport, authentication, host trust, channels, shell
tether-core        session orchestration + the public API
tether-render      terminal state → GPU draw            (Phase 4)
tether-view/swift  SwiftUI / UIKit view + bindings      (Phase 4)
tether-app/apple   the flagship application             (Phase 5)
```

A consuming application imports `tether-core` and `tether-view/swift`.

`tether-terminal` links no SSH symbol. That is not a convention — it is how the
byte-stream boundary is proved by the build graph rather than asserted in a
document.

## Building

For repository development, install the commit gate once per clone with
`python3 scripts/install-hooks.py`. See [commit checks](docs/commit-checks.md)
for platform coverage and required tools.

Build with the latest stable Rust (`rustup update stable`); the current minimum is 1.98.1.

```bash
cargo build
cargo test
cargo tree -p tether-terminal   # must show no russh
```

## Where to start

`.claude/notes/remote-platform-spec.md` is the defining specification, mirrored
byte-for-byte in `molab-apple`, a consumer.

The native macOS app now includes a modular frontend and an optional tmux workspace.
See [frontend extensions and tmux](docs/plugins.md) for building, extending and using it.

### Window appearance (Windows)

**Settings → Appearance** offers Frosted glass (Acrylic), Mica and Solid.
Background opacity controls one tint across the entire workspace while keeping text and the cursor
opaque. The default tint is 60%, adjustable from 50% to 100%, matching macOS.
Windows uses Acrylic and can fall back to solid
when transparency effects are unavailable. See [Windows appearance](docs/windows-appearance.md).

### Quick Terminal (Windows)

Press **Ctrl+Backquote** (Ctrl + the OEM backquote key) to summon the existing
workspace into the top half of the pointer's monitor. Press it again to hide;
sessions keep running. The notification-area icon also shows/hides it; its menu
restores the normal window or quits through the existing close confirmation.

**Settings → Quick Terminal** controls enabling, auto-hide, notification-area icon
and normal-window topmost behavior. Change the primary/secondary global shortcut
under **Settings → Key Bindings → Toggle Quick Terminal**. Conflicts with another
application are reported in Settings. The workspace menu and command palette
also offer Toggle Quick Terminal, Restore Window and Keep Window on Top.

### Quick Terminal (macOS)

Press **Control + `** or click the terminal icon in the macOS menu bar to show
or hide the current workspace at the top of the display under the pointer.
Hiding keeps terminals and splits running. The shortcut works while another app
is active and can be changed under **Settings → Key Bindings → Toggle Quick
Terminal** (two bindings are supported). Right-click the menu-bar icon for Show/Hide Quick Terminal,
Restore Window, Close Window, and Quit Tether. Closing the window keeps its
sessions; Quit uses the normal live-terminal confirmation.

**Settings → General → Quick Terminal** controls the menu-bar button and global
hotkey, plus automatic hiding when switching apps. Turn off **Hide When
Switching Apps** to keep the floating terminal visible. **Keep Window on Top**
also applies to the ordinary window. **Window → Return to Normal Window** restores
its previous size and position. Shortcut registration conflicts appear in General
settings; choose another combination there rather than changing another app.

MIT licensed.
