# CLAUDE.md

## What this repo is

Tether is a set of Rust components an application imports to embed a working
SSH terminal, with platform-native bindings and views on top. Two products live
here: **the SDK**, which is the primary product, and **the app**, a standalone
terminal client shipped on the App Store and the first consumer of that SDK.

The value is composition, boundaries and API — not engine internals. SSH,
cryptography, VT parsing and text shaping are composed from mature upstream
crates (`russh`, `aws-lc-rs`, `alacritty_terminal`, `wgpu`, `cosmic-text`).

The defining document is `.claude/notes/remote-platform-spec.md`, mirrored
byte-for-byte in `molab-apple`, an external consumer. The two copies must change
together. Read it before touching architecture.

## Where things live

- `Cargo.toml`, `crates/` — the SDK. Crates appear only when they have work;
  an empty crate for a future phase is a layer added "because it may be useful
  later", which the spec forbids (§22).
- `app/` — the app, a consumer like any other. `app/Packages/TetherFrontend`
  is the plugin kit and shared UI; `app/Packages/TetherPluginHost` is the
  web plugin host; `app/Plugins/` holds the built-in plugins.
  Everything tmux the app shows is in `app/Plugins/Tmux`, and the app reaches
  it only through `TetherPluginKit`.
- `.claude/notes/` — the specification and durable project knowledge.

## Law (never violated)

- **Compose, do not rewrite.** Engines come from mature upstream crates judged
  on the spec's five criteria (§5). A boundary exists to keep a dependency's
  types out of our public surface, never to re-implement it.
- **The SDK does not know its consumers.** No consumer's name, identifier,
  storage path or wording appears in the components.
- **`tether-terminal` links no SSH symbol.** `cargo tree -p tether-terminal`
  is the test (spec §3, §8).
- **Producers do not reach each other.** A session reads from a `Producer`;
  SSH and a local PTY are two of them, and neither crate appears in the
  other's tree. `cargo tree -p tether-local | grep russh` is the test.
- **Backends are confined.** `russh` types stop inside `tether-ssh`;
  `portable-pty` and `anyhow` stop inside `tether-local`;
  `alacritty_terminal` types stop inside `tether-terminal`; `russh-sftp`
  types stop inside `tether-files` (spec §8).
- **Headless first.** The core must connect, authenticate, run a shell and
  expose terminal state with no UI framework linked. An acceptance criterion,
  not an aspiration (spec §15).
- **No UI toolkit types in the frontend contract** (spec §14).
- **The app names no plugin.** A plugin reaches the app through
  `TetherPluginKit`; the one line that knows it by name registers it.
  `grep -ri tmux app/Sources` is the test.
- **Errors are ours.** Backend error numbers are diagnostic context, never the
  public API (spec §18).
- **Keyboard-interactive is generic.** Never encode `keyboard-interactive ==
  OTP` (spec §10).
- **Conservative security defaults.** Strict host verification, no trust-all,
  no secret logging; remote data is untrusted input (spec §18).
- **The window is silent chrome.** Icon-only controls, names on hover;
  no sentences in the window; compact, not decorated
  (`.claude/notes/law.md`, app-ui-chrome). Native menus and the command
  palette still use words. Alerts are a title and a verb.
- **Web plugins are web software.** A plugin installed after shipment is a
  manifest plus HTML, CSS, and JavaScript in an isolated web view. The host
  does not load downloaded native code. Host access goes through the
  capability API (`.claude/notes/law.md`, web-plugin-host).
- **One dialog path.** Every alert, confirmation and question — the app's,
  a plugin's, a handshake's — is a TetherUI `Dialog` shown by
  `DialogPresenter`: `.dialog(for:)` from a view, `DialogPresenter.ask` from
  code that waits. Only `DialogSurface{Phone,Mac}.swift` touch
  `UIAlertController` or `NSAlert`; grepping for `.alert(` is the test.
  A failure a person has to act on is one of these, naming the host and the
  reason — not a page left in a tab. Their own *no* ends quietly.

## Working here

```bash
./scripts/tether.sh --help                        # every flag, in one place
./scripts/tether.sh --check                       # cargo clippy --workspace -- -D warnings
./scripts/tether.sh --test                        # cargo test --workspace
./scripts/tether.sh --build-app                   # macOS Tether.app
./scripts/tether.sh --build-app-ios               # simulator Tether.app + install
./scripts/tether.sh --build-xcframework           # TetherFFI.xcframework + bindings
./scripts/tether.sh --test-tmux                   # loopback OpenSSH + real tmux
./scripts/tether.sh --verify-consumer             # PATH-stripped consumer build

cargo build
cargo test
cargo tree -p tether-terminal    # must show no russh
cargo tree -p tether-local       # must show no russh either

swift test --package-path swift                        # the SDK's Swift facade
swift test --package-path app/Packages/TetherFrontend  # frontend, incl. render cost
swift test --package-path app/Packages/TetherPluginHost # web plugin host
swift test --package-path app/Plugins/Tmux             # the built-in plugins, no server needed
swift test --package-path app/Plugins/Files
swift test --package-path app                          # the app's own state
```

CI runs everything above. The app links nothing from outside this repository;
its plugins are the built-in ones. Nothing in any suite touches the system
keychain.

iOS targets are not installed by default:
`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`.

iCloud sync needs a team-signed build; an ad-hoc one runs but never syncs.
The app is `Roy-Kid.Tether` with container `iCloud.Roy-Kid.Tether`, both
registered to the team that ships it (`dev.tether.app` belongs to someone
else). Profiles come from Xcode's own store, asked for once per machine and
again when they expire:

```bash
./scripts/tether.sh --provision --team <TEAMID>          # needs xcodegen + Xcode signed in
./scripts/tether.sh --build-app --team <TEAMID>          # or export TETHER_TEAM
./scripts/tether.sh --build-app-ios --phone "<name>" --team <TEAMID>
```

Two things run on demand rather than on every change:

```bash
./scripts/tether.sh --fuzz 60                     # needs nightly + cargo-fuzz
cargo run --release -p tether-ffi --bin frame-cost   # what a frame costs
```

The terminal's compatibility corpus (`crates/tether-terminal/tests/corpus/`)
is real output recorded from real programs, committed so the test needs none
of them. Re-recording is deliberate:

```bash
./scripts/tether.sh --record-corpus               # re-record the §12 workloads
TETHER_BLESS=1 cargo test -p tether-terminal --test corpus   # then read the diff
```

## Status

Phase 0 is closed: the binding seam, `aws-lc-rs` for Apple targets and the
artifact shape are decided and exercised by CI.

Phase 2's acceptance is in place — recorded §12 workloads asserted against
screen state, and `cargo-fuzz` over everything that reads remote bytes. Phase 4
draws with Metal on both platforms; the SwiftUI canvas stays as the fallback
and a setting. The Metal path is tested by drawing off screen and reading the
pixels back, since nothing else in CI would notice it drawing nothing.

A login asks through dialogs, and reads a question that comes back as the
answer before it refused. A refused saved password is never sent again, and a
password is only offered to be kept once it has worked. The password asked
before dialling is a dialog too, not a sheet.

A session reads from a `Producer` rather than from SSH, so
`tether-local` gives the same `TerminalSession` over a shell on this machine.
The app lists `localhost` as an ordinary host and opens one at launch; there is
no kind field, and there should not be one.

A session also leases a `Connection` — the right to run *another* command where
its shell is running. SSH answers with a second channel and
this machine with a second process, so tmux works on both and is written once.

There is one kind of host, and one source of truth: the host library,
synchronized through iCloud. A host that arrives from another device on the
same Apple ID is trusted — no review. Private keys travel with that library,
so the other device logs in with the same key; a host with none gets one
from Create SSH Key, and that key syncs too. Passwords stay on the device
that saved them. A deleted host takes its keys out of the keychain. On a Mac
`~/.ssh/config`
feeds the library (`ConfigImport`): a new stanza is added, an edited stanza
updates its host, a stanza taken out leaves its host in place. Nothing under
`~/.ssh` is ever written: a change or deletion in Tether stays in Tether, and
a stanza nobody touched never undoes it. The sync button reads the whole
library through iCloud again. `~/.ssh/known_hosts` vouches for keys ssh
already trusts, and objects to ones it does not.

tmux is a tab plugin: an accessory on every terminal tab,
and content that can stand in for the tab's shell. The app draws what the
attachment reports and never learns what a session is. A pane's history is
kept and scrolled here: a control-mode client is sent a pane's output, never
what tmux draws for copy mode.

Files are SFTP over the same lease: the `sftp` subsystem
on a remote session, `ssh -s` through a ControlMaster, and this machine's own
`sftp-server` locally — one client, `tether-files`, over any byte stream.
Transfers land whole or not at all, and nothing is replaced unless asked.
The browser is a tab plugin kept in the inspector, and a
path printed in the terminal opens with ⌘-click, a force click or a
long-press: the terminal finds the shape, the plugin
checks it exists.

A consumer can hand its palette down, and the engine answers the far side's
colour queries from it. Cells still report colour *names* —
§12 is untouched — but "what is your background?" is a question only whoever
draws can answer, and a program that hears nothing assumes a dark terminal and
paints itself over the window. A consumer that says nothing is still silent.
