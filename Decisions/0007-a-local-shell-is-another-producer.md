# 0007 — A local shell is another producer, not another kind of session

Status: accepted
Date: 2026-09-18
Phase: 3 (composition)

## Context

The app could open a terminal on a machine somewhere else and on no machine at
all. Opening one on *this* machine — the thing every terminal application does
first, and the only one that works on a train — was not possible, and there was
nowhere for it to go: `tether-core::TerminalSession::start` took a
`tether_ssh::Shell` by name, so "a session" and "a session over SSH" were the
same sentence.

Spec §8 had already said what the shape should be: "an SSH interactive shell is
one producer. tmux panes and recordings are others." §3 had already said why it
matters: "a consumer who wants to render a local terminal, a recording or a
serial port must be able to take `tether-terminal` and `tether-render` without
SSH coming along." Both were true of the *terminal* crate and false of the
composition crate above it.

Two shapes were available:

1. A second session type — `LocalSession` beside `TerminalSession`, and a
   frontend that knows which it is holding.
2. One session type over a producer boundary, chosen once at construction.

## Decision

**A `Producer` trait in `tether-core`, and one `TerminalSession` over it.**

```rust
pub trait Producer: Send + 'static {
    fn write(&mut self, bytes: Vec<u8>) -> impl Future<Output = Result<(), ProducerError>> + Send;
    fn resize(&mut self, size: ScreenSize) -> impl Future<Output = Result<(), ProducerError>> + Send;
    fn next_output(&mut self) -> impl Future<Output = Option<Output>> + Send;
    fn close(self) -> impl Future<Output = ()> + Send;
}
```

`tether-local` is the second implementation: a new crate that owns a
pseudo-terminal and the process on it, exactly as `tether-ssh` owns a channel
and the shell on it. It links no SSH symbol, and `tether-ssh` links no PTY
backend; CI asserts both with `cargo tree`, the way the existing law about
`tether-terminal` is asserted.

Static dispatch, not `dyn`. A producer is chosen once, when a session is
created, and never changes, so the indirection would buy nothing and cost an
allocation per chunk of output — on the path `Decisions/0006` is about.

**`portable-pty` 0.9** provides the pseudo-terminal, judged on §5's criteria:

| | |
|---|---|
| Governance | the `wezterm` GitHub organisation |
| Activity | 0.9.0 released 2025-02-11 |
| Adoption | 15.6M downloads, 8.2M in the last 90 days |
| Baggage | Windows ConPTY and a serial-port crate ride along unused; the API is blocking |
| Licence | MIT, ours |

It is infrastructure, not architecture: it provides a primitive and dictates
nothing about how our code is shaped. `pty-process` fits our async runtime
better — it is tokio-native where this is not — but it is personally
maintained on self-hosted git with a seventh of the reach, and §5 prefers the
one that gets forked if it is ever abandoned over the one with the nicer
signature.

## Consequences

**The frontend has one kind of session.** `SessionTab.dial` has the only branch
in the app; below it the repaint loop, scrolling, resizing, input encoding and
closing were written once and do not know which they got. The Swift facade
gained `TerminalSession.local(_:)` beside `.connect(to:trusting:offering:)` and
nothing else.

**The blocking API costs one thread per session.** `portable-pty` hands back
`io::Read`/`io::Write`, so reading runs on a dedicated thread — not
`spawn_blocking`, whose pool is sized for work that finishes and whose shutdown
waits for it. Writes do use `spawn_blocking`, and `Producer::write` takes
`&mut self` so that "two writes are never in flight" is checked by the compiler
rather than asked for in a comment. The channel between the reader and the
engine is bounded, so a program printing faster than the terminal can parse is
answered with backpressure through the kernel rather than with unbounded
growth.

**Two defects only a real shell would have shown.** Both were found by running
the app, not by the tests, and both are now covered by tests that fail without
the fix:

*The environment carried a claim we had no right to pass on.* A child inherits
this process's environment, and whatever launched the app may have set
`TERM_PROGRAM`. With `TERM_PROGRAM=Apple_Terminal`, zsh sources
`/etc/zshrc_Apple_Terminal` and replays a saved Terminal.app session — so the
very first local terminal opened onto output from a window closed days
earlier. `TERM` is set because it describes what can be *drawn*, which is a
question this crate can answer; `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` and
`TERM_SESSION_ID` are removed, because a component may not name its consumer
and therefore cannot answer "which terminal is this?" honestly.

*A resize could be applied and then quietly undone.* `TIOCSWINSZ` returned
success, the kernel confirmed the new size on read-back — and a few
milliseconds later the size was back to what it had been, permanently, for the
life of that terminal. The shell is the one doing it: it reads the size when
it starts, caches it, and writes its copy back. Measured at roughly one resize
in ten, and not a corner case at all, because a tab is opened and *then* laid
out — which is a resize arriving a few milliseconds after the shell started.
The symptom is a terminal stuck at 80×24 inside a wider pane, with nothing in
any log.

Retrying on failure cannot fix it, because there is no failure at the time:
the write that undoes it lands after the write that worked. So the requested
size is *held* — for the first 1.5 seconds of a session a thread re-asserts it
whenever the far end disagrees, then stops. A terminal emulator owns its size;
the program inside it does not get a vote.

**`TerminalSession::connection()` is now a question, not a guarantee.** It
returns `None` for a local session, because there is no second channel to open
on a shell that never crossed a network. A frontend asks rather than knowing —
which is how the tmux plugin already worked, so nothing changed for it.

**iOS answers `false`.** There is no `fork`/`exec` outside the sandbox, so
`local_shell_available()` is the question a consumer asks *before* offering the
feature, and `TetherError::Unsupported` is what it gets if it asks anyway. The
crate still compiles for iOS, so the UniFFI surface is identical on every
target and the shared Swift code has no `#if` in it.

**`ShellRefused` lost the word "server".** It now reads "could not open a
shell", because by the time a consumer sees it, whether the shell was going to
run here or elsewhere is not something it branches on (§18).

**The composition test names three engines.** `composition()` returns `russh`,
`portable-pty` and `alacritty_terminal`; an about screen that named only some
of what a build is made of would be worse than one that named none.

**The end-to-end composition test now runs everywhere.** `tether-core`'s SSH
test is skipped unless a server is configured, which meant the composition was
usually proved by nothing. `tests/local.rs` needs no server and exercises the
same path, so `cargo test` covers a real byte stream from software we did not
write landing on a screen, on every machine, every time.

## In the app

`localhost` is a host in the sidebar, above the saved ones. It is not stored in
`hosts.json`, it cannot be deleted, and it has no editor — a label, a hostname,
a port and a user are four answers it already knows. It is recognised by a
fixed identifier rather than by its hostname, because reaching `localhost`
*over SSH* is an ordinary thing to want and guessing from the name would take
that connection away from whoever set it up.

There is deliberately no kind field on `Host` and no second section in the
list. The place where a local terminal differs from a remote one is the
producer, and that difference is spent inside the SDK.

A new **General** preference, on by default, opens a terminal on this machine
at launch. A terminal application that opens on nothing asks a person to do
setup before it has been useful once, and the one machine it can always reach
needs none. `--open` still wins: someone who named a host meant that host.
