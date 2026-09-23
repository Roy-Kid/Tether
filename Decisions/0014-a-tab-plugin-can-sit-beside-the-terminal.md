# 0014 — A tab plugin can sit beside the terminal

Status: accepted
Date: 2026-09-23
Amends: 0012

## Context

0012 gave a tab plugin two places to draw: a popover behind its accessory,
for choosing, and content that stands in for the shell. tmux needed both.

Files needs neither. A browser of the machine the shell is on is looked at
*while* the shell runs — an agent writes a plot, the person looks at it,
the agent writes another. A popover closes the moment the terminal is
clicked, and standing in for the shell hides the thing producing the files.
What it needs is the inspector, which the window already has and which 0012
only let a plugin fill while it was showing instead of the shell.

Two smaller things came with it. A browser that knows a path wants to type
it at the prompt, and 0012 gave a plugin no way to reach the terminal. And a
file dropped on a remote terminal has nowhere to go: its local path means
nothing on the far side.

## Decision

**`TabAccessory` says where it opens.** `placement: .popover` (the default,
and what tmux keeps) or `.inspector`. On a Mac an inspector accessory toggles
the window's inspector onto that plugin's `inspector()`; the host remembers
the plugin, not the tab, so switching tabs shows the same plugin for the tab
now in front. On a phone, which has neither, both placements open a sheet;
an inspector accessory's sheet shows `inspector()`.

**`TabContext.insertText`** types text at the tab's prompt, as a paste. The
host owns the terminal; a plugin never writes to it directly.

**`TabAttachment.receive(files:)`**, defaulting to `false`. Files dropped on
a *remote* terminal are offered to each attachment in turn, and the first to
take them decides what the drop means. On this machine the host types the
paths itself, which is what every terminal does and all a local shell needs.
So that a drop works before any accessory has been opened, the host attaches
the tab's plugins when something is dropped: `attach` is called the first
time a tab *needs* a plugin, not only when its accessory opens.

## Consequences

- Files is `app/Plugins/Files`, registered with one line. The CI check that
  the app names no plugin covers it as it covers tmux.
- Dropping a screenshot on a remote terminal uploads it to the directory the
  browser is in (home, until the terminal reports its working directory)
  and types its path — the gesture that hands a picture to an agent on the
  far side.
- tmux is unchanged: its accessory is a popover, its content still stands in
  for the shell, and it declines drops.
- The inspector's order is: a workspace plugin's, then the inspector
  plugin's for the current tab, then whatever stands in for the shell, then
  the connection form.
- On a Mac the browser is a tree, as an editor's explorer is: a folder opens
  in place under its name, listed the first time it opens. A narrow column
  beside a running program cannot afford to replace its whole view every
  time someone looks one level down. A phone keeps drilling down, one
  directory a screen, which is what its width allows.
