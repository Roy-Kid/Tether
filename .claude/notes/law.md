# Law

Inviolable rules. One block per rule. CLAUDE.md carries a one-line pointer; this file is the canonical text.

<!-- mol:law:id:app-ui-chrome -->
## App UI chrome

The window is a terminal, not a document full of labels. In-window chrome
(titlebar, tab accessories, status bar, pickers, overlays) is **icon-only**,
with the name on **hover tooltip**. Write no copy in the window, or as little
as a tab title and a status word. Keep the layout compact and spare: a 32pt
tab strip (the system titlebar, where the traffic lights centre), 24pt
host bar, no second toolbar, no decorated empty states.

macOS menus and the command palette still use words — they are not window
chrome. Accessibility labels stay; they are not on-screen copy.

Alerts, confirmations and sheets follow the same silence: a title and a
verb. One extra line only when the consequence is not the button. No
tutorials, no menu paths, no “detach instead”.

Names are data, not copy. A host, a session or a window may be named in
the window — the host bar names the host, a tab's caption the tmux session
standing in for its shell — because that is where a person is, not words
about it. Each name once: the strip does not repeat the host bar.

**Rule**: Icon-only + tooltip in the window. No sentences where a symbol will
do; names of what is open are allowed. Compact, not decorated. Alerts:
title + verb.

<!-- mol:law:id:web-plugin-host -->
## Web plugin host

Software installed after the app ships is web software: a manifest plus
HTML, CSS, and JavaScript, run in an isolated web view. The host does not
download or execute native code for a plugin. A plugin reaches the
application only through the capability API. It does not import the app,
the SDK, or a filesystem path.

**Rule**: Store plugins are web software. No downloaded native code. Host
access goes through the capability API.
