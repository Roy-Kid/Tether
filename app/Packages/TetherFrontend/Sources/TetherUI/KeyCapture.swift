import SwiftUI
import Tether

private struct TerminalInputEnabledKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var terminalInputEnabled: Bool {
    get { self[TerminalInputEnabledKey.self] }
    set { self[TerminalInputEnabledKey.self] = newValue }
  }
}

extension View {
  /// Suspend terminal responders while presenting controls above the workspace.
  /// The selected terminal regains focus when input is enabled again.
  public func terminalInputEnabled(_ enabled: Bool) -> some View {
    environment(\.terminalInputEnabled, enabled)
  }
}

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
  @Environment(\.terminalInputEnabled) private var inputEnabled
  let onInput: (TerminalInput) -> Void
  var active: Bool
  var onFocus: () -> Void
  /// Lines to move the viewport; positive goes back into history.
  var onScroll: (Int32) -> Void
  /// How tall a row is, so a trackpad's point deltas become whole lines.
  var lineHeight: CGFloat
  var links: TerminalLinks = .none
  var geometry: CellGeometry = .empty
  var cursorRect: CGRect = .zero
  var onHover: (TerminalLink?) -> Void = { _ in }

  /// The surface's own: pointing at text needs to know where the cells are.
  init(
    onInput: @escaping (TerminalInput) -> Void, active: Bool, lineHeight: CGFloat,
    onFocus: @escaping () -> Void, onScroll: @escaping (Int32) -> Void,
    links: TerminalLinks, geometry: CellGeometry, cursorRect: CGRect,
    onHover: @escaping (TerminalLink?) -> Void
  ) {
    self.init(
      onInput: onInput, active: active, lineHeight: lineHeight, onFocus: onFocus,
      onScroll: onScroll)
    self.links = links
    self.geometry = geometry
    self.cursorRect = cursorRect
    self.onHover = onHover
  }

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
        onInput: onInput, active: active && inputEnabled, onFocus: onFocus,
        onScroll: onScroll, lineHeight: lineHeight,
        links: links, geometry: geometry, cursorRect: cursorRect, onHover: onHover)
    #else
      // A phone drags the screen itself; the capture view owns that gesture
      // for the same reason the Mac's owns the wheel.
      PhoneKeyCapture(
        onInput: onInput, active: active && inputEnabled, lineHeight: lineHeight,
        onFocus: onFocus, onScroll: onScroll, links: links, geometry: geometry)
    #endif
  }
}
