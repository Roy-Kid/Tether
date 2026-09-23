# 0015 — A path on screen is something to open

Status: accepted
Date: 2026-09-23
Builds on: 0013, 0014

## Context

The files an agent makes are announced in its output: `Wrote
figures/energy.png`, `Updated docs/report.pdf:12`. The person reading that
line wants the file, and the file browser (0014) is one column over. Moving
the eyes from the line to the browser, finding the directory and the file —
for something the screen already names — is the gap this closes.

Three questions had to be answered somewhere:

1. What text is a path? The terminal's.
2. Does it exist, and where? Only something holding the connection can say.
3. What does pointing at it do? The frontend's gestures, and the plugins'
   answers.

## Decision

**The terminal finds shapes; it never checks them.**
`Terminal::link_at(position)` returns what the text under a cell names — an
`OSC 8` hyperlink the program attached, a web address, or something shaped
like a path — with where it is drawn, so it can be underlined. It reads
wrapped rows as one line, keeps `:line:column` apart from the path, and drops
what surrounds a path in prose (quotes, backticks, a leading `@`, trailing
punctuation, Markdown's brackets). It is asked when a person points, not
every frame, so nothing is added to a frame or to the damage contract.

**The terminal remembers where the shell said it was.** `OSC 7`
(`file://host/path`) and iTerm's `OSC 1337 ; CurrentDir=` are read by a
scanner beside the engine, which ignores both. `working_directory()` is
`None` until one arrives; nothing is guessed.

Both parsers read remote bytes, so both are bounded — 4096 characters of
line, 4096 bytes of report — and fuzzed (`terminal_links`, every cell of a
narrow screen pointed at).

**Plugins say what a link means.** `TabAttachment.actions(for:)` is given a
`PointedLink` — the link, and a way to ask where the program that printed
it was — and returns `LinkActions`: what opening does, a preview for a
phone's long-press, menu commands, and whether the thing named exists. The
Files plugin resolves a relative path against that directory, then the
browser's, then home, and acts only on one the far side says exists.
`TabContext` gained `workingDirectory`, `showAccessory`, and `linkActions`
— the tab's combined answer, for a plugin that draws terminals of its own.

**tmux panes point the same way.** A pane's engine answers `link_at` and
remembers its own `OSC 7`; the pane's directory is that, or else tmux's own
`#{pane_current_path}`, which tmux reads from the process and knows even
when the shell reports nothing. The tmux plugin asks the tab's
`linkActions`, so Files answers there without either plugin knowing the
other.

**The gestures are ones a program in the terminal cannot claim.** Agents and
editors turn on mouse reporting, so a plain click stays theirs:

| | Mac | Phone |
|---|---|---|
| Underline | ⌘ held over the text | — |
| Open | ⌘-click; a force click | tap the preview |
| Menu | right-click | long-press, with a preview of the file |

A web address opens in the browser without asking a plugin. The menu always
has the text itself to copy.

## Consequences

- Quick Look moved out of the browser's view: a path clicked in the
  terminal opens whether or not the browser is showing.
- An underline is a promise, so it is checked. A ⌘-hover underlines at once,
  dotted, and asks the far side: solid if the path is there, gone if not.
  One lookup per link hovered, not per mouse movement, remembered for three
  seconds so the click that follows does not ask again.
- A relative path is resolved from where it was printed. A program that
  changed directory without reporting it prints paths relative to somewhere
  this cannot know; the browser's directory and home are the fallbacks.
- On this machine a previewed file is the file itself, not a copy: the
  file session says when it is local (`RemoteFiles::is_local`).

### Found on the way

A Swift process that linked Tether died with `SIGPIPE` in three test runs
out of ten: a tmux client had exited before the newline that detaches it
was written. Rust binaries ignore that signal before `main`, so no Rust
test ever saw it; an application starts with the default, which ends the
process. `tether-local` now sets `F_SETNOSIGPIPE` on every pipe it writes
to a child, on Apple platforms, so a child that stops reading is an error.
The local `sftp-server` of 0013 would have hit the same path.
