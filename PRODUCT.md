# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

Native on each OS, following that OS's own conventions. Today the app ships
SwiftUI on Mac, iPhone and iPad, and all three count equally. Android,
Windows and Linux are planned, and the design must leave room for them. Each
platform gets its own native app; none is a port of another, and none is a
web wrapper.

## Users

Anyone whose real work happens on remote machines. Two groups, neither ahead
of the other:

- **Developers and operators** who spend the day in remote shells across many
  servers.
- **Researchers** who SSH into clusters and lab machines to start and watch
  long jobs, often inside tmux, and move files in and out.

Both groups open the app on a Mac at a desk, on an iPad, or on an iPhone while
away from the desk. On every device the job is the same: reach a host, get a
shell or tmux session back, and carry on.

The SDK has a second audience: **application developers** who import Tether to
embed a working SSH terminal in their own app, without having to learn SSH,
PTYs, VT parsing, GPU rendering or tmux.

## Product Purpose

The repository holds two products. **The SDK** comes first: Rust components,
with platform-native bindings and views, that an application imports to get a
working, styleable SSH terminal. **The app** is a standalone terminal client
on the App Store and the SDK's first consumer. It proves the frontend contract
is enough to build a real product on.

The app has succeeded when people use it as their daily remote terminal on
every device they own. The SDK has succeeded when an unrelated app imports two
components and gets a working SSH terminal without a UI framework coming along
(spec §27).

## Positioning

Claims a neighbouring product (Termius, Blink, Prompt) cannot honestly copy:

- **tmux as native UI.** Tether is a tmux control-mode client. Sessions,
  windows and panes show up as native pickers, tabs and panes, and each
  pane's scrollback is kept and scrolled locally.
- **One lease carries everything.** A session leases its connection, and
  files (SFTP), port forwards and extra tmux commands all ride on that lease.
  They work the same way on `localhost`.
- **Quiet native chrome.** The window is a terminal, not a dashboard. Chrome
  is icon-only, rendering is Metal, and the menus are the system's own.
- **Open SDK underneath.** The app is built on an MIT-licensed embeddable SDK
  that any application can import. Plugins installed after shipment are
  sandboxed web software.
- **Free and cross-platform.** Free to use. Native on Apple platforms today,
  with other operating systems planned.

## Operating Context

- **Host library.** There is one kind of host and one source of truth, and it
  syncs through iCloud. `localhost` is an ordinary host and opens at launch.
  On a Mac, `~/.ssh/config` is read and offered for import but never written.
  `~/.ssh/known_hosts` is only read.
- **Object hierarchy.** Host → terminal tab (a stable place to work) →
  original shell or tmux session → window → pane.
- **Mac workspace.** One 32pt tab strip that shares its row with the traffic
  lights, plus a 24pt host bar. Commands live in the native menu bar, a
  command menu (⌘⇧O) and quick switch (⌘P). The inspector opens on
  demand. Zen mode hides all chrome.
- **iPhone and iPad.** The same host library and sync. A plugin accessory
  opens as a full-screen cover with its own navigation and Close button. A
  native keyboard accessory supplies modifier keys.
- **Plugins.** Built-in tab plugins (tmux, Files, Ports) reach the app only
  through `TetherPluginKit`. Plugins installed later are web plugins (a
  manifest plus HTML, CSS and JS) that reach the host only through the
  capability API.
- **Connection lifecycle states:** Connecting, Needs authentication,
  Connected, Disconnected, Ended. After a disconnect the last screen stays
  visible as a read-only snapshot.

## Capabilities and Constraints

- SSH comes from `russh`, the terminal engine from `alacritty_terminal`, and
  crypto from `aws-lc-rs`. Tether owns the composition and does not rewrite
  these engines (spec §2, §5).
- The SDK never knows its consumers. No consumer's name, wording or storage
  path appears in the components, and the frontend contract carries no UI
  toolkit types (spec §14).
- Authentication: keys, passwords and generic keyboard-interactive (never
  assumed to mean OTP). Host verification is strict. Passwords stay on the
  device that saved them. Private keys sync with the host library.
- Every alert, confirmation and question goes through one path: a TetherUI
  `Dialog` shown by `DialogPresenter`.
- The terminal answers colour queries from the consumer's palette. Cells still
  report colour names.
- Terminal font size is independent of the chrome and is never shrunk to make
  the layout more compact.
- **Undecided:** which non-Apple platform comes first, and when. There is no
  pricing model beyond "free".

**Terminology:** host, terminal tab, original shell, session / window / pane,
accessory, inspector, lease, Zen.

## Brand Commitments

- **Name:** Tether. App ID `Roy-Kid.Tether`.
- **The window is silent chrome** (`.claude/notes/law.md`, app-ui-chrome). In
  the window: icon-only controls with the name in a hover tooltip, no
  sentences, compact rather than decorated, and no decorated empty states.
  Native menus and the command menu still use words. Accessibility labels
  stay.
- **Voice of alerts:** a title and a verb. Add one more line only when the
  button cannot convey the consequence. No tutorials, no menu paths, no
  suggested alternatives.
- **A person's own *no* ends quietly.** A failure the person has to act on is
  a dialog that names the host and the reason.
- **Native type and semantic system colours** in the UI, following
  light/dark mode and increased contrast.

## Evidence on Hand

- Logo: `assets/logo.png`. App icon: `app/Assets.xcassets/AppIcon.appiconset/`.
- Final Mac workspace design: `design/compact-zen/final/` (`SPEC.md` plus 16
  state SVGs) and the Figma file "Tether Compact-Zen", Page 6. The SVGs use
  Inter and JetBrains Mono only as rendering stand-ins; they are not the app's
  fonts. The hosts and output shown in them are illustrative.
- Real terminal output recorded from real programs:
  `crates/tether-terminal/tests/corpus/`.
- Frame-cost measurement: `cargo run --release -p tether-ffi --bin frame-cost`.
- Developer docs: `docs/plugins.md`, `.claude/notes/remote-platform-spec.md`,
  `.claude/notes/web-plugin-host.md`.
- **Absent, so never fabricate:** testimonials, user counts, App Store
  ratings, press, performance benchmarks against other apps, and dates for
  non-Apple platforms.

## Product Principles

1. **The terminal is the product.** Chrome gets out of the way. Every pixel
   that isn't terminal output has to earn its place.
2. **Native on every device.** Each platform gets its own conventions, and
   Mac, iPad and iPhone are equally first-class. Nothing is ported from a
   website or from another OS.
3. **The remote is the truth.** Show the real tmux, connection and file state.
   Never fake a window, a session or a "Connected" status, and never quietly
   create something in place of what disappeared.
4. **Compose, don't reinvent.** Build on mature engines and native platform
   components. What Tether owns is the seams and the experience.
5. **Secure by default, quietly.** Strict trust and no secret logging, with no
   lectures about either.

## Accessibility & Inclusion

- VoiceOver labels on every icon-only control, with connection state spoken
  aloud.
- Dynamic Type on iOS, with a 44pt minimum touch target. At accessibility text
  sizes, names wrap and sheets open at full height.
- Increased contrast adds explicit selection borders. Reduce Transparency
  makes floating surfaces opaque. Reduce Motion turns off transitions.
- IME and text editing take priority over app shortcuts. Terminal keys that
  the app hasn't claimed reach the shell untouched.
- Release checks cover 860×520 and 1100×700 Mac windows, narrow and landscape
  iPhones with the keyboard open, and full and narrow iPad windows, in both
  light and dark mode.
