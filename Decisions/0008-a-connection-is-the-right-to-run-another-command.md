# 0008 — A connection is the right to run another command, not an SSH session

Status: accepted
Date: 2026-09-18
Phase: 3 (composition)

## Context

`Decisions/0007` made a session one type over two producers, and closed with a
line that turned out to be the next problem: "`TerminalSession::connection()`
is now a question, not a guarantee. It returns `None` for a local session,
because there is no second channel to open on a shell that never crossed a
network."

That sentence is true about SSH channels and wrong about what the method is
for. Nothing above it wanted a channel. The one caller — the tmux workspace —
wanted to *run another command where this session's shell is running*: `tmux
list-sessions` for its answer, `tmux -C attach-session` for a stream. Both are
perfectly ordinary things to do on this machine, and they were refused because
the only implementation happened to be an SSH one.

The symptom was a person opening a terminal on their own Mac, starting tmux in
it, and finding the tmux button greyed out with "connect to a host first" — on
a machine that was already running the tmux they wanted to attach to.

Two shapes were available:

1. A second path: the frontend asks whether the session is local and, if so,
   runs tmux through a local-only code path of its own.
2. One `Connection` above both, with the tmux workspace unchanged.

The first is the shape §8 exists to prevent. It also fails a smaller test: the
tmux protocol code would have had to be reachable from two places, and the
second one would have been the one nobody tested.

## Decision

**A `Connection` in `tether-core`, and one tmux workspace over it.**

```rust
pub enum Connection {
    Remote(Arc<tether_ssh::Session>),
    Local,
}

impl Connection {
    pub async fn capture(&self, command: &str, limit: usize) -> Result<Capture, ConnectionError>;
    pub async fn open(&self, command: &str) -> Result<Channel, ConnectionError>;
}
```

`capture` runs a command for its answer; `open` keeps its input and output. A
`Channel` is the duplex half, and `tether-tmux`'s existing `Transport` is
implemented over it once — so the adapter that used to speak only to
`tether_ssh::Shell` now speaks to either, and everything above it is untouched.

**`tether-local` grew the non-terminal half it was missing.** `Shell` exists
because a person is going to look at the output; `Stream` and `Command::capture`
exist because a program is. The difference is a pseudo-terminal, and it is not
a detail: a pty echoes what is written to it and rewrites the line endings
coming back, both of which a control protocol reads as data. So these use
pipes, keep standard error apart, and report an exit status.

**A local command is run through a login shell.** Both halves are load-bearing.
A *shell*, because the caller writes one command line with the quoting a shell
understands, and that is exactly what the remote arm hands to `sshd` — two arms
that parsed the same string differently would be a seam that only looked like
one. A *login* shell, because a launched application inherits almost no `PATH`:
without the profile, `tmux` installed by Homebrew is simply not found, and the
failure reads as "you have no tmux" to somebody looking at tmux.

## Consequences

**`TerminalSession::connection()` answers `Some` for a local session**, and its
documentation is now about what it is rather than what it is over. The tmux
plugin, the Swift facade and the frontend contract did not change: the frontend
already asked rather than assumed, which is why this was a one-line difference
for it.

**The UniFFI surface is byte-identical.** `RemoteConnection` keeps its name and
its five methods; only what backs it changed. The name is now the weakest part
of this — it leases the right to run a command on this machine as readily as on
another — and renaming it is a separate, mechanical change that this one did
not need to make.

**Standard error on a held-open channel is a failure, not output.** A command
being spoken to in a protocol answers on standard output; what it puts on the
other stream is a complaint, and feeding that to a parser as though it were an
answer is how a protocol error becomes a mystery. It is also why the stream is
read at all: a pipe nobody empties fills, and a program blocked writing to it
never speaks again.

**A refused capture kills the child.** Both pipes are drained at once — reading
one to its end first deadlocks on a program that fills the other — and a
program that blew the limit on one stream is still filling the other, so the
child is killed rather than waited for. Found by writing the test before the
code: `yes | capture(4 KiB)` hung the whole suite.

**`tether-local` still links no SSH symbol** and `tether-ssh` still links no
PTY backend. `cargo tree` asserts both, unchanged.

## In the app

The tmux button is enabled on a local session, and opening a workspace lists,
creates, attaches to and ends tmux sessions on this machine — including ones
started from an ordinary terminal, which is the case that prompted this.

Reconnecting a local workspace does not present the password sheet. The sheet
exists to answer a stranger, and there is none; this is the same reason opening
a local host presents no sheet either.

The tmux plugin's wording lost the word "remote". "Your remote tasks keep
running" is a promise about somebody else's computer, and the workspace is now
just as likely to be about this one.

`LocalTmuxTests` is the SSH round trip with the handshake deleted — no host, no
key, no fingerprint, the same calls in the same order — and it runs wherever
tmux is installed, which the SSH one does not.
