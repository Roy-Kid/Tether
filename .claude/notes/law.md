# Law

Inviolable rules. One block per rule. CLAUDE.md carries a one-line pointer; this file is the canonical text.

<!-- mol:law:id:app-ui-chrome -->
## App UI chrome

The window is a terminal, not a document full of labels. In-window chrome
(titlebar, tab accessories, status bar, pickers, overlays) is **icon-only**,
with the name on **hover tooltip**. Write no copy in the window, or as little
as a tab title and a status word. Keep the layout compact and spare: 36pt
tabs, 24pt host bar, no second toolbar, no decorated empty states.

macOS menus and the command palette still use words — they are not window
chrome. Accessibility labels stay; they are not on-screen copy.

Alerts, confirmations and sheets follow the same silence: a title and a
verb. One extra line only when the consequence is not the button. No
tutorials, no menu paths, no “detach instead”.

**Rule**: Icon-only + tooltip in the window. No sentences where a symbol will
do. Compact, not decorated. Alerts: title + verb.

<!-- mol:law:id:web-plugin-host -->
## Web plugin host

Software installed after the app ships is web software: a manifest plus
HTML, CSS, and JavaScript, run in an isolated web view. The host does not
download or execute native code for a plugin. A plugin reaches the
application only through the capability API. It does not import the app,
the SDK, or a filesystem path.

**Rule**: Store plugins are web software. No downloaded native code. Host
access goes through the capability API.
