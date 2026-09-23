# 0012 — A plugin can live inside a tab

Status: accepted
Date: 2026-09-23
Amends: 0005

## Context

0005 said registering a package is the only change the app needs to gain an
extension. For tmux, the first extension, that was not true. The plugin's
`launch` opened a workspace the app never used: the app checked for
`TmuxPlugin.id` and ran its own picker instead. tmux was also hard-coded in
seven app files: the tab model held a `TmuxWorkspaceModel`, `TabSet` decided
which tab owned which session, the tab strip drew a tmux button, the root
view swapped in tmux content and presented the new-session sheet, and the
menu bar had a tmux menu. Turning the plugin off was a string comparison
against `"dev.tether.tmux"`.

The seam could not express what tmux is. `PluginWorkspace` is a tab of its
own. tmux is not: it hangs off a terminal tab the person already has, and it
stands in for that tab's shell without replacing the tab. With no way to say
that, the host said it for the plugin — and the first plugin, which should be
the one proving the seam works, proved nothing about it.

## Decision

**TetherPluginKit gains a second plugin shape, `TabPlugin`.** It provides:

- a `TabAccessory` — a symbol, and a name used for the tooltip and the menu.
- `attach(to: TabContext) -> TabAttachment`, called once per tab the first
  time the accessory opens there, and only when the tab has a lease.

A `TabAttachment` tells the host what to draw and nothing else:

- whether it stands in for the shell (`isShowing`)
- the subtitle beside the tab's name
- whether it lost its connection
- the one line under the close confirmation
- its menu commands
- its content, inspector and accessory content

The host forwards two lifetime events: a replaced lease and closing.
`TabContext` carries back the few things only the host can do: focus the tab,
dismiss the accessory, present a sheet over the window.

**Everything tmux the app shows lives in `app/Plugins/Tmux/`:**

- the per-tab model (`TmuxTab`)
- the picker, and the new-session sheet
- the content and inspector
- the rule that a session belongs to one tab

That rule needs every tab the plugin is attached to. The plugin holds them;
the host, which does not know what a session is, could not.

**The chrome vocabulary moves to TetherUI.** A plugin draws chrome in the same
window — a popover on a tab, a row in a sheet. `Theme`, `UIStyle`,
`ChromeButtonStyle` and the row modifiers are public in TetherUI, so plugin
chrome and window chrome come from one place. Host-tile tints and the window's
own metrics (`Chrome`) stay in the app.

**The SDK's tmux stays where it is.** `tether-tmux`, the FFI adapter and the
Swift facade are SDK components. A consumer can use tmux without this app's
plugin, and the SDK does not know its consumers (spec §4). This decision is
about the app, not the components.

## Consequences

- `grep -i tmux app/Sources` finds two lines: the import and
  `registry.register(TmuxPlugin())`. CI fails on a third.
- The plugin's tests run with no tmux server and no app: ownership, the shell
  switch, detaching and closing are asserted against a `TabContext` a test
  builds. CI runs them; the plugin needs nothing from outside this
  repository.
- The app's tests assert the host's side against a stub attachment:
  - subtitle, status and caption come from the attachment
  - closing a tab closes it
  - disabling a plugin detaches it from every tab
- The menu bar has no tmux menu. Each tab plugin gets a submenu under Terminal,
  named after the plugin. The host cannot add a top-level menu per plugin
  without knowing its plugins in advance.
- The command palette no longer has its own "Attach tmux Session…" item. The
  plugin's entry opens its accessory on the current tab, the same thing
  launching any tab plugin does.
- Nerve, a workspace plugin outside this repository, is untouched:
  `PluginWorkspace` and `PluginContext` keep their shape.
