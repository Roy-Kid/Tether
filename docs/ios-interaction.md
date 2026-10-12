# iOS interaction follow-up — 2026-10-08

## Platform design

- Plugin accessories open as full-screen covers on iOS, including iPad. The host
  owns one navigation stack and an explicit Close control. Files keeps its folder
  navigation and search; tmux keeps its shell/session picker; Ports gets the same
  dismissal path. macOS retains its popovers and inspector.
- Plugin-owned forms use full-screen covers too. The root presents a form opened
  directly from a command; an accessory presents its own nested form. Only one
  presenter owns a given form. Native authentication alerts retain the existing
  dialog path.
- iOS continues to use Tether's host library and sync. No system SSH configuration
  or ControlMaster UI was added.

## Terminal editing and commands

- Long-press ordinary terminal text for Select Text, Select Line, Copy and Paste.
  The phone session now passes the workspace link handlers into its terminal;
  existing file/link actions remain in that menu. Selection uses the shared grid
  extraction, including wide characters and hidden cells.
- Drag with a selection to extend it across rows. Tap to clear selection. Without
  a selection, dragging keeps scrollback or remote mouse behavior.
- Native Copy uses the displayed selection. Paste sends a terminal paste event,
  preserving bracketed-paste handling in the engine, rather than individual keys.
  Both are unavailable while terminal input is suspended.
- A compact Commands menu provides touch access to the actions that belong to the
  screen on show, in sections: the terminal (Rename, Reconnect), the hosts, and on a
  wide iPad the splits. External keyboard commands use the shared SwiftUI shortcut
  definitions and scene commands, whether or not the menu lists them. Modal plugin
  pages and editing/dialog states disable workspace shortcuts. Tab-bar and Zen
  actions stay Mac-only.

## Navigation and size classes (2026-10-12)

- One terminal shows at a time; the navigation title is the switcher. Its menu lists
  every open terminal by host, with its state and the current one checked, then New
  Terminal. With nothing open there is no menu, so no chevron.
- One `NavigationSplitView` serves every size, so rotating or resizing keeps the
  terminal's view and focus. On iPhone it still behaves as a stack.
- On an iPad with regular width and height the inspector is a column, and terminals
  split side by side as on the Mac (equal shares, no drag handles). A large iPhone
  in landscape gets neither.
- With a compact height and the keyboard up, the navigation bar and host column hide;
  they return when the keyboard goes down.
- Key Bindings appear in Settings on iPad, recorded from a hardware keyboard.

## Validation

- iOS app compilation passed on arm64 Simulator.
- iPhone 17e / iOS 26.5 Simulator: 48 frontend tests passed, including three new
  phone editing tests. System pasteboard reading is not part of those unit tests;
  paste event routing is tested without triggering OS consent UI.
- macOS regressions: frontend 56, App 260, Files 77 and tmux 27 tests passed.
- Simulator.app is absent from this Xcode installation, so full-screen presentation,
  selection drag ergonomics, clipboard consent and external-keyboard dispatch still
  need manual device acceptance. No screenshot-level or physical-device claim.
- Existing unrelated plugin-host compiler and FFI deployment-target linker warnings
  remain in the current working tree.
