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

MIT licensed.
