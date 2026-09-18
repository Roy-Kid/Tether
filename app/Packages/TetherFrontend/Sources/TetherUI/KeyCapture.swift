import SwiftUI
import Tether

/// Turns what the person did into a [`TerminalInput`].
///
/// Reports a key, not bytes. What a key means on the wire depends on modes
/// the *remote* program set — the same arrow is `ESC [ A` or `ESC O A` — and
/// only the engine knows those, so deciding here would be guessing (spec §12).
///
/// The two platforms disagree about almost everything below this line: what a
/// key event is, how an input method composes, whether there is a keyboard at
/// all. They agree on this signature, which is the only part the rest of the
/// app is allowed to know.
public struct KeyCapture: View {
  let onInput: (TerminalInput) -> Void
  var active: Bool
  var onFocus: () -> Void
  /// Lines to move the viewport; positive goes back into history.
  var onScroll: (Int32) -> Void
  /// How tall a row is, so a trackpad's point deltas become whole lines.
  var lineHeight: CGFloat

  public init(
    onInput: @escaping (TerminalInput) -> Void,
    active: Bool = true,
    lineHeight: CGFloat = 17,
    onFocus: @escaping () -> Void = {},
    onScroll: @escaping (Int32) -> Void = { _ in }
  ) {
    self.active = active
    self.lineHeight = lineHeight
    self.onFocus = onFocus
    self.onScroll = onScroll
    self.onInput = onInput
  }

  public var body: some View {
    #if os(macOS)
      // A wheel is a Mac's way into the history; a phone drags the screen
      // itself, which the surface handles as a gesture.
      MacKeyCapture(
        onInput: onInput, active: active, onFocus: onFocus,
        onScroll: onScroll, lineHeight: lineHeight)
    #else
      PhoneKeyCapture(onInput: onInput, active: active, onFocus: onFocus)
    #endif
  }
}
