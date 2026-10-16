# 0020 — Windows plugins are the same seam

Status: accepted
Date: 2026-09-26
Amends: 0012, 0014

## Context

The Windows window had grown a files button, a files column and a
`FilesVisible` flag. That is the shape 0012 was written to get rid of: the
host naming the extension and deciding where it lives. A second extension
would have meant a second button written in the window.

The file browser itself could already list, upload and preview. What it
could not do is the thing 0014 exists for. A path dropped on the terminal,
or printed by a program there, never reached it. The terminal checked a
path against this machine's disk, which is the wrong disk once the shell
is somewhere else.

## Decision

**The window hosts tab plugins. It does not name them.**

`PluginRegistry` is the list. One line in the composition root registers
each plugin. An inspector plugin is a button and a column, both taken from
the accessory: a glyph, a name, and a view. Which plugin is open is
remembered for the window, so the next tab shows the same kind of thing.
Turning one off detaches it from every tab.

Files is that plugin (`dev.tether.files`), the same id as on Mac. A drop
on a remote terminal, and on WSL, is uploaded to where the shell is and
the path it will recognise is typed. A drop on a local Windows shell is
typed as a path, which is what 0014 says this machine needs. A path in the
terminal is checked through the plugin's lease, then opened or revealed.
The terminal still only finds the shape.

## What this does not decide

A popover placement, a workspace plugin, or a menu of plugin commands
beyond a link's own. Nothing on Windows has asked for those yet.
