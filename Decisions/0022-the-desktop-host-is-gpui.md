# 0022 — The desktop host is GPUI

Status: accepted
Date: 2026-11-09
Amends: 0021 (hosts), the Windows app shape of 0017

## Context

Windows and macOS each carry a whole application: about 11k lines of C# and
XAML, and about 38k lines of Swift. Most of it is the same workspace twice —
tabs, splits, hosts, login questions, the palette, settings, plugins — and
the two drift (`docs/windows-parity.md` exists to track the drift).

`tether-ui` began as shared chrome painted with GPUI inside a window the
native host kept. GPUI cannot do that. `xgpui` 3.0.1 opens its own window
and has no parent-view option; `Application::run_embedded` needs a platform
whose run loop returns, and the macOS one blocks. Embedding would mean
writing and keeping a GPUI platform of our own, to share one tab strip.

## Decision

**On Windows and macOS, GPUI owns the window, and the workspace is written
once in Rust.** iOS stays SwiftUI.

- `desktop/` is the host: a consumer, like `app/` and `app-win/`. It opens
  the window, owns the workspace model and composes the SDK.
- `crates/tether-ui` is the shared chrome. It lays out and paints; it opens
  no window and calls no platform API.
- The terminal is a child surface over the terminal rect: a `CAMetalLayer`
  subview on a Mac, a child HWND on Windows. `tether-render` keeps its own
  wgpu device; GPUI keeps its own. Neither links the other.
- What belongs to a platform — Keychain and Credential Manager, iCloud,
  Handoff, the credential extension, a global hotkey, the menu-bar or tray
  icon, a web view — is a small module under `desktop/src/platform/`, behind
  a trait the workspace calls. Mature crates are composed (`wry`,
  `global-hotkey`, `tray-icon`) rather than rewritten.

The estimate is about 85–90% shared. What forks is the platform module:
roughly 2.5–3.5k lines on a Mac (iCloud, Handoff, Credential Exchange, the
quick-terminal panel) and 1–1.5k on Windows (WSL, DPAPI).

## Consequences

- `app-win/` and the SwiftUI Mac shell stay until the GPUI host reaches
  them, then retire. Two production workspaces is the cost of the interim,
  not the end state.
- Models that are Swift and C# today (`TabSet`, `WorkspaceSplit`, the host
  library, ssh config, `Dialog`, key bindings) move into Rust once.
  The iCloud record format is shared with iOS and does not change.
- Device qualification under 0021 applies to the GPUI host as it did to
  the native ones.

## What this does not decide

Linux packaging, the App Store shape of a Rust binary, or the plugin
contract that replaces `TetherPluginKit` for GPUI views.
