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
  is the plugin kit and shared UI; `app/Plugins/` holds the built-in plugins.
  Everything tmux the app shows is in `app/Plugins/Tmux`, and the app reaches
  it only through `TetherPluginKit` (Decisions/0012).
- `Decisions/` — ADRs. Anything expensive to reverse gets one (spec §25).
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
  other's tree. `cargo tree -p tether-local | grep russh` is the test
  (Decisions/0007).
- **Backends are confined.** `russh` types stop inside `tether-ssh`;
  `portable-pty` and `anyhow` stop inside `tether-local`;
  `alacritty_terminal` types stop inside `tether-terminal`; `russh-sftp`
  types stop inside `tether-files` (spec §8, Decisions/0013).
- **Headless first.** The core must connect, authenticate, run a shell and
  expose terminal state with no UI framework linked. An acceptance criterion,
  not an aspiration (spec §15).
- **No UI toolkit types in the frontend contract** (spec §14).
- **The app names no plugin.** A plugin reaches the app through
  `TetherPluginKit`; the one line that knows it by name registers it.
  `grep -ri tmux app/Sources` is the test (Decisions/0012).
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

## Working here

```bash
cargo build
cargo test
cargo tree -p tether-terminal    # must show no russh
cargo tree -p tether-local       # must show no russh either

swift test --package-path swift                        # the SDK's Swift facade
swift test --package-path app/Packages/TetherFrontend  # frontend, incl. render cost
swift test --package-path app/Plugins/Tmux             # the built-in plugins, no server needed
swift test --package-path app/Plugins/Files
swift test --package-path app                          # the app's own state, local only
```

CI runs everything above except the last: the app links whichever extensions a
person has, some of which live outside this repository, and Tether's CI must
not fail for something that is not Tether. Nothing in any suite touches the
system keychain.

iOS targets are not installed by default:
`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`.

Two things run on demand rather than on every change:

```bash
scripts/fuzz.sh 60                          # needs nightly + cargo-fuzz
cargo run --release -p tether-ffi --bin frame-cost   # what a frame costs
```

The terminal's compatibility corpus (`crates/tether-terminal/tests/corpus/`)
is real output recorded from real programs, committed so the test needs none
of them. Re-recording is deliberate:

```bash
python3 scripts/record-corpus.py            # re-record the §12 workloads
TETHER_BLESS=1 cargo test -p tether-terminal --test corpus   # then read the diff
```

## Status

Phase 0 is closed: the binding seam, `aws-lc-rs` for Apple targets and the
artifact shape are decided and exercised by CI (Decisions/0002–0004).

Phase 2's acceptance is in place — recorded §12 workloads asserted against
screen state, and `cargo-fuzz` over everything that reads remote bytes. Phase 4
has a measurement and no renderer yet: `Decisions/0006` records what a frame
costs today and the trigger for the GPU stack.

A session reads from a `Producer` rather than from SSH (`Decisions/0007`), so
`tether-local` gives the same `TerminalSession` over a shell on this machine.
The app lists `localhost` as an ordinary host and opens one at launch; there is
no kind field, and there should not be one.

A session also leases a `Connection` — the right to run *another* command where
its shell is running (`Decisions/0008`). SSH answers with a second channel and
this machine with a second process, so tmux works on both and is written once.

The app's host list is `~/.ssh/config` and nothing else (`Decisions/0009`). The
file is edited in place, never regenerated: everything in it this app does not
understand has to come back out unchanged.

tmux is a tab plugin (`Decisions/0012`): an accessory on every terminal tab,
and content that can stand in for the tab's shell. The app draws what the
attachment reports and never learns what a session is.

Files are SFTP over the same lease (`Decisions/0013`): the `sftp` subsystem
on a remote session, `ssh -s` through a ControlMaster, and this machine's own
`sftp-server` locally — one client, `tether-files`, over any byte stream.
Transfers land whole or not at all, and nothing is replaced unless asked.
The browser is a tab plugin kept in the inspector (`Decisions/0014`), and a
path printed in the terminal opens with ⌘-click, a force click or a
long-press (`Decisions/0015`): the terminal finds the shape, the plugin
checks it exists.

A consumer can hand its palette down, and the engine answers the far side's
colour queries from it (`Decisions/0011`). Cells still report colour *names* —
§12 is untouched — but "what is your background?" is a question only whoever
draws can answer, and a program that hears nothing assumes a dark terminal and
paints itself over the window. A consumer that says nothing is still silent.
