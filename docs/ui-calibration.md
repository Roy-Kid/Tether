# UI calibration

## Visual rules

- App controls use `UIStyle` in `Design.swift`: platform-specific typography,
  row/control sizes, shared spacing, selection feedback and floating surfaces.
- macOS keeps the 36 pt tab strip, 24 pt host bar and 12 pt terminal gutter.
  iOS custom rows use Dynamic Type and a minimum 44 pt target; accessibility
  text sizes allow names to wrap. Terminal font preferences remain independent.
- Native forms, navigation, settings and authentication alerts retain their
  platform presentation. Custom floating panels share material, border and
  shadow rules, with opaque backgrounds when Reduce Transparency is enabled.
- Selected custom rows keep their existing checkmark or tab indicator, expose
  selection to accessibility, and gain an explicit border at increased contrast.
  Status buttons expose a spoken connection state. Identity colors remain stable.
- The command panel is constrained by the available width and height. The Mac
  tmux picker fits short content and scrolls long lists.
- The tmux package owns private visual roles; no app dependency or public SDK
  interface was introduced. Authentication logic and terminal rendering are unchanged.

References: [Apple typography](https://developer.apple.com/design/human-interface-guidelines/typography),
[Apple materials](https://developer.apple.com/design/human-interface-guidelines/materials).

## Validation — 2026-09-22

- macOS build passed; `build/Tether.app` was packaged and opened.
- App tests: 80 passed. Frontend tests: 8 passed, including grid and render-cost checks.
- iOS Simulator build passed with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`.
  A generic all-architecture build cannot link x86_64: the existing FFI artifact
  provides the arm64 simulator slice.
- Runtime accessibility inspection verified the new host connection value,
  host filtering and its empty result, the command-menu keyboard shortcut,
  and arrow-key selection after focusing its search field.
- Terminal geometry constants are unchanged; runtime visible row/column counts
  have not been measured.

## Remaining visual verification

The computer-use screenshot endpoint returned only a small application thumbnail,
including after raising the window, so reliable before/after screenshots could not
be collected. Pixel-level visual acceptance is not claimed. The iOS check was a
build, not a simulator interaction test.

Before release, inspect 860×520 and 1100×700 Mac windows, narrow/landscape iPhones
with the keyboard open, and full/narrow iPad windows. Cover light/dark appearance,
large accessibility text, increased contrast, reduced transparency, VoiceOver,
long names, many tabs/hosts, authentication, connection errors, and tmux state
changes. Authentication alerts retain the full fingerprint and native controls.

The current Xcode installation also lacks `Contents/Developer/Applications/Simulator.app`.
Simulator SDK compilation is available, but interactive iPhone/iPad review is not.
`InterfacePreviews.swift` provides offline light/dark host editors, large-text
authentication, and a 20-tab Mac workspace for the next full Xcode review.

## Native interaction follow-up

- Host picker focuses search after presentation, supports arrow keys, Return,
  Escape and the accessibility escape action. Keyboard highlight is separate
  from the current-host checkmark, and follows the actual displayed host order.
- Command search retains the selected command by identity when filtering,
  skips disabled commands, clears selection on empty results, and supports
  native text-field submission. Recent hosts are no longer listed twice.
- The menu bar advertises Command-Shift-P for Command Menu; Control-Shift-P
  remains an alternate shortcut. Quick Switch still uses Command-P.
- iOS tmux sheets have a native navigation title and Close control, and open
  at full height for accessibility text sizes. Host rows offer swipe-to-edit
  without destructive full-swipe behavior; scrolling can dismiss search input.
- The new-session field requests focus, disables automatic capitalization and
  correction on iOS, and rejects blank/busy submission from Return as well as
  from the Create button.
- Validation: 83 App tests passed (including three picker-navigation regression
  tests); the arm64 iOS Simulator build passed. This follow-up does not add a
  pixel-level visual acceptance claim.

## Three-platform polish

- iPhone host lists use grouped native rows; wide iPad windows use sidebar
  styling. Both show an Add Host action when empty. iPad uses a balanced split
  view. The universal bundle declares all
  four iPad orientations separately from iPhone orientations.
- Mac tab titles have a width limit and a full-title tooltip, keeping long
  titles from consuming the strip. Existing chrome heights and terminal margins
  remain unchanged. Disconnected tmux no longer shows a connected green dot.
- Terminal input is suspended under application pickers, sheets and alerts,
  and reactivated on dismissal. iOS no longer requests keyboard focus on each
  output frame, so manually dismissing the keyboard survives terminal output.
- The native keyboard accessory has 44 pt minimum keys, horizontal overflow
  on narrow phones, a centered width limit on iPad, an explicit keyboard-dismiss
  action, and selected accessibility traits for latched modifiers.
- tmux creation keeps the form open while running and retains the draft/error
  on failure. Retry reuses an already-created remote session if attachment failed.
  Successful attachment closes the form. The operation is protected from
  accidental dismissal while in flight.
- Reduced Motion disables the terminal scrollback button transition animation.

Frontend consumers can apply `view.terminalInputEnabled(false)` (from `TetherUI`)
to suspend terminal responders throughout that subtree; the default is `true`.
`TmuxTab.create(onSuccess:)` reports success once the new session is attached.

Validation: 85 App tests passed, including creation/attachment failure recovery;
8 frontend tests passed. macOS packaging and arm64 iOS Simulator compilation
passed. The iPhone/iPad bundle manifest and build script syntax were checked.
Mac runtime inspection confirmed that Command-Shift-H focuses host search,
typing filters without an extra click, and Escape dismisses the picker.
No physical-device, pixel-level or comprehensive VoiceOver acceptance is claimed.
