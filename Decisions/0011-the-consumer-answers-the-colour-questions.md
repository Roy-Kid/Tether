# 0011 — The consumer answers the colour questions

Status: accepted
Date: 2026-09-22
Phase: 4 (rendering)

## Context

On a phone in light mode, a remote session was black. Measured from a
screenshot: the terminal area was `#141414`, uniformly, with 24-bit greens and
reds where a diff was shown. Neither of those is a colour this app draws with —
its dark background is `(18, 20, 26)` and its light one `(251, 251, 253)`. The
far side had painted every cell explicitly, and the app had drawn exactly what
it was told.

The far side painted itself dark because it asked whether the terminal was dark
and got no answer. A program asks with `OSC 11 ; ? BEL`; the convention when
nothing comes back is to assume a dark terminal. The engine was raising that
question — `Event::ColorRequest` — and `tether-terminal` dropped it, in the same
arm as the clipboard and text-area queries, with a comment saying the ones that
need state we do not have are "answered by the consumer, not invented here".
Nothing in any consumer answered them. The comment described a plan, and the
grep for `ColorRequest` returned one line: the discard.

This sits on top of spec §12, which says the engine reports colour *names* and
the consumer owns what they look like. That rule is about the screen. The
question the far side asks is not about the screen — it is about the thing that
draws, and only the consumer can answer it.

It also could not be worked around on the drawing side. Once a program has
painted a cell with an explicit colour, that colour *is* the content; repainting
it with the local background would take the red out of a diff and the highlight
out of a selection.

## Decision

**A consumer may hand its palette down, and the engine answers colour queries
from it.** `Terminal::set_palette` takes the sixteen ANSI colours plus
foreground, background and cursor. `OSC 4`, `OSC 10`, `OSC 11` and `OSC 12`
queries are answered from that palette through the existing reply path — the
same one that carries cursor-position reports back to the far side.

**A consumer that says nothing changes nothing.** With no palette, the queries
are dropped exactly as before. Silence is a supported answer, not a gap to fill
with a default.

**Nothing is invented.** Only what the consumer actually chose is answered:
indices 0–15, and the three that have no number. A query for the 6×6×6 cube or
the greys above it goes unanswered rather than being served a value nobody
picked, even though that cube is standard and could be computed.

**The palette is settable at any time.** Appearance is not a launch-time fact. A
person switching their window to light is the same question being asked again,
so `set_palette` is a method rather than an option on a builder, and the app
calls it whenever the palette it draws with changes.

**One place decides which palette that is.** `Palette.chosen(setting:scheme:)`
in the frontend is used both by the surface that draws and by the session that
tells the far side. A screen drawn light while the far side was told "dark" is
worse than either mistake on its own.

## Consequences

The round trip is tested over a real PTY, not mocked: a shell emits the query,
reads its own input back, and prints what arrived
(`crates/tether-core/tests/local.rs`). The silent case is tested the same way
and asserts an empty answer.

`TerminalPalette` crosses the FFI as a record of `ColorValue`s. The sixteen ANSI
colours are a `Vec` on the wire — uniffi has no fixed-size array — and a list of
any other length is refused with an error rather than padded.

A frontend now has a reason to tell the SDK about its colours, which it did not
before. That is one more thing a consumer can get wrong by not doing it; the
failure mode is today's behaviour, which is why it is not an error to omit.

## Not decided here

**tmux.** This does nothing for a tmux pane, and the screenshot that started
this was tmux. A pane's output reaches us through `capture-pane`; the program's
query goes to tmux, not to us, and tmux answers it from what it knows about its
own clients. A control-mode client can supply that answer with
`refresh-client -r %pane:<report>`, which needs tmux 3.4 — the machine in
question runs 3.2a. Until that is done, a program inside tmux will still assume
a dark terminal.

**`COLORFGBG`.** The other channel a program uses to learn the background.
Rejected for now on three counts: an SSH server will not accept an unlisted
environment variable, tmux cannot deliver one to a program that is already
running, and setting it would force the palette into every construction path
rather than being settable when appearance changes. `Rgb::is_dark` exists for a
consumer that wants to fill it in itself.

**Reading the far side's `OSC 11` *set*.** A program can also tell the terminal
what background to use. We ignore it, as we ignore every other attempt to
choose our colours for us.
