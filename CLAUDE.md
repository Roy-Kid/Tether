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
- **Every window exists once.** A thing is managed on one page, and every
  way to it opens that page rather than a sheet or window of its own. Hosts
  are Settings ▸ Identities: the host picker's list and add buttons, Edit…,
  Identity…, Manage Hosts and a password manager's import all open Settings
  there, with the host, its editor or the import pushed over the list
  (`SettingsRoute`).

## Working here

Install the repository-local commit gate once per clone with
`python scripts/install-hooks.py`. It rejects partial staging and runs the same
host-platform checks as CI. See `docs/commit-checks.md` for tool requirements,
the audited failure history and cross-platform coverage. Run
`python scripts/check.py` to check the working tree before staging. Commits go
straight to dev and master. A push runs only the Windows tests
(`windows.yml`), the one thing a Mac cannot check before committing; the whole
gate runs on CI nightly (`ci.yml`). Each CI job is one `check.py --job <name>`,
the same function a commit runs.

```bash
./scripts/tether.sh --help                        # every flag, in one place
./scripts/tether.sh --check                       # cargo clippy --workspace --all-targets -- -D warnings
./scripts/tether.sh --test                        # cargo test --workspace
./scripts/tether.sh --build-app                   # macOS Tether.app
./scripts/tether.sh --build-app-ios               # simulator Tether.app + install
./scripts/tether.sh --build-xcframework           # TetherFFI.xcframework + bindings
./scripts/tether.sh --verify-consumer             # PATH-stripped consumer build

cargo build
cargo test
cargo tree -p tether-terminal    # must show no russh
cargo tree -p tether-local       # must show no russh either

swift test --package-path swift                        # the SDK's Swift facade
swift test --package-path app/Packages/TetherFrontend  # frontend
swift test --package-path app/Packages/TetherPluginHost # web plugin host
swift test --package-path app/Plugins/Tmux             # the built-in plugins, no server needed
swift test --package-path app/Plugins/Files
swift test --package-path app/Plugins/Ports
swift test --package-path app                          # the app's own state
(cd app/Packages/TetherFrontend && xcodebuild test -scheme TetherFrontend-Package \
  -destination "platform=iOS Simulator,id=<udid>")     # the phone's frontend tests
```

CI runs the cargo and Swift commands above; the app builds, the
consumer check and the shipping XCFramework run here. The app links nothing from outside this repository;
its plugins are the built-in ones. Nothing in any suite touches the system
keychain. Nerve's native panel is linked only on a Mac with `../nerve` beside
this checkout, and never under `TETHER_HERMETIC=1`, which the commit gate sets.

The compilers are pinned: `rust-toolchain.toml` and `.xcode-version`. CI uses
both, and the Apple gate refuses another Xcode — a pass on a different
compiler is not a pass. Change the file to upgrade.

A Swift test suite that touches a window or an AppKit event declares
`.appKitEventLoop` (`TetherTestSupport`). Without it a stray window-server
event can end the test process with status 0 mid-run; the gate blocks any
`swift test` run that does not print its summary.

iOS targets are not installed by default:
`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`.

When replacing an installed macOS app, preserve its signing team and application
identifier (`codesign -dv` and `codesign -d --entitlements :-`). Build with the
existing team's `--team`; replacing a team-signed app with an ad-hoc build can
make its saved Data Protection Keychain credentials unavailable. Do not treat
the resulting missing-credential error as a reason to re-enter or delete secrets.

iCloud sync needs a team-signed build; an ad-hoc one runs but never syncs,
and carries no credential provider, so it cannot import from a password
manager either. The app is `Roy-Kid.Tether` with container
`iCloud.Roy-Kid.Tether` and extension `Roy-Kid.Tether.CredentialProvider`
(AutoFill capability on both), all registered to the team that ships it
(`dev.tether.app` belongs to someone else). Profiles come from Xcode's own
store, asked for once per machine and again when they expire:

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
uses the shared Rust wgpu renderer on Windows and Apple, with native platform
hosts. Apple uses the Metal backend; there is no separate terminal Canvas or
Swift Metal painter. Pixel readback tests exercise the same shared render pass.
Device release qualification is recorded separately (ADR 0021).

A login asks through dialogs, and reads a question that comes back as the
answer before it refused. A refused saved password is never sent again, and a
password typed at a login is only offered to be kept once it has worked. The
password asked before dialling is a dialog too, not a sheet.

A session reads from a `Producer` rather than from SSH, so
`tether-local` gives the same `TerminalSession` over a shell on this machine.
The app lists `localhost` as an ordinary host and opens one at launch; there is
no kind field, and there should not be one.

A session also leases a `Connection` — the right to run *another* command where
its shell is running. SSH answers with a second channel and
this machine with a second process, so tmux works on both and is written once.

There is one kind of host, and one source of truth: the host library,
synchronized through iCloud. A host that arrives from another device on the
same Apple ID is trusted — no review. A host's private key, password and
one-time-code seed are equals, and all three travel with that library: what
one device keeps, the others log in with, and letting go of one here lets go
of it everywhere. A host with no key gets one from Create SSH Key, and that
key syncs too. Each secret stays in its device's keychain; the host's record
carries it — the password and seed as encrypted fields — and nothing logs
it. A deleted host takes its secrets out of the keychain.

A password manager can export into the library (Credential Exchange). The
export is started there; Tether is offered as a destination because it
carries a credential provider extension that provides nothing, and the
export arrives at the app as a one-time token. Only the host library
filters it: an item that names an existing host — by its name or address,
for that host's user — is offered for that host, keys, passwords and codes
alike, with what the host already has left unchosen; the rest is folded
away to be given a host by hand or left behind. An import never creates a
host, and nothing the person did not choose is stored. On a Mac
`~/.ssh/config` is read, never written. On launch, when the file would
change a host, a dialog asks whether to import it; agreeing copies the file
over the hosts it names. Declining leaves the library until the next open,
or until Import in Settings, which overwrites those hosts without asking
again. A host the file does not name stays. A quiet read (`ConfigImport`)
still updates a stanza someone edited and never undoes an untouched one.
`~/.ssh/known_hosts` is still only read. The sync button reads the whole
library through iCloud again.

On a Mac the workspace window is the app's own `NSPanel`
(`WorkspaceWindow`), hosting the SwiftUI root, not a SwiftUI scene. The
quick terminal is a separate panel, non-activating from initialization;
never change a live panel's activation style to summon it. Its shortcut
belongs to the unified key binding manager (`quickTerminal`), not a second
shortcut preference. It follows the pointer's display by default, or targets
a display selected in Settings by its stable identity, not its list position.
An unavailable selected display falls back to the pointer's display without
forgetting the selection. It takes key without activating Tether, with floating
and full-screen/Spaces behavior. Summoning
or hiding it leaves the main window's frame, visibility and native full-screen
state alone. Keep Window on Top remains an independent main-window setting.
The main workspace and its quick panel share one effective interaction host.
Ordinary terminal commands and their questions belong to that host: opening,
closing, reconnecting, renaming, splitting, picking a host and using the command
palette must not implicitly replace the quick panel with the main window.
The effective host is application state, not AppKit's main window, and is not
lost merely because a menu, a child dialog or another app takes key focus.
An already presented blocking question keeps its host until its surface is
gone; hiding or switching that host must not silently cancel the question.
Plugin UI and Settings remain explicit main-window capabilities; global
library imports and startup handoff keep their single primary owner. Shared
session changes remain shared; effective-host routing does not copy sessions.
The primary workspace and quick panel remember tab-bar visibility separately.
The workspace keeps its existing preference; quick inherits it once when no
quick preference exists. Extra windows keep local choices for their lifetime.
Tab layout remains shared, and Zen temporarily hides rather than rewrites either choice.
The quick panel shares the main workspace's terminal sessions, not its native
views; plugin pages and inspectors stay in the main window. Each terminal
surface has its own renderer, only the front window drives session sizing,
and the quick surface must not consume the main surface's incremental damage.
The Dock and menu-bar icon open the main window where it was; only the quick
terminal command summons the panel. Settings → General → When the Window Closes
chooses Quit or Hide. Hide orders the window out, leaves the Dock, and keeps
the menu-bar icon; that icon brings the window and the Dock icon back. Quit
still confirms live terminals. Hiding the quick panel closes no session. Its size
and the ordinary frame are remembered apart: dragged in either place, that
place comes back that size. Returning to either lays the terminal out again,
so the grid fills the window it is in. The grid rests on the bottom edge,
and a status line meets the status bar. Quick Terminal's position is Top,
Bottom, Left, Right or Floating; Top is the default. Each placement remembers
its own size, and Reset Size resets only that placement. Floating starts
centered and keeps a dragged position while its target display is unchanged
and the frame still fits. These choose placement, not the panel's window level
or activation behavior. Menu enabling reads the model (`TabSet.menuShortcuts`);
a focused value does not leave an `NSHostingView`.

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

Space previews; Download keeps a copy that is nobody's business after; on a
Mac, opening a file edits it. The copy opens in whatever the Mac opens it
with and stays watched: a save is written back, and a change on the far side
is brought into the copy, as soon as either happens. A save lands only while
the far side's file is still the one that was opened, and a far-side change
lands only while the copy still matches it. Otherwise the person chooses
Replace, Save as Copy or Discard My Changes; nothing is overwritten unasked.
What lands, lands in the same file, never swapped in under its name: an app
that has it open keeps it, and one that reloads on change does.
An edit copy
lives under Application Support and goes once it is written back and its
editor has quit; one with an edit not yet written back stays across launches.
Previews and other copies that can be fetched again live in this account's
own temporary directory, never the shared `/tmp`, closed to other accounts.
Settings ▸ Files shows where they are and what they take, and clears them.

A session can forward the user's own loopback ports on that machine to this
device. The listener is on this side of the lease — a direct-tcpip channel,
`ssh -W` through a ControlMaster, or the port itself when the shell is
already here — and the inspector lists them.

A consumer can hand its palette down, and the engine answers the far side's
colour queries from it. Cells still report colour *names* —
§12 is untouched — but "what is your background?" is a question only whoever
draws can answer, and a program that hears nothing assumes a dark terminal and
paints itself over the window. A consumer that says nothing is still silent.
