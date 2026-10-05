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
/// Ctrl and Opt on a phone, shared by the key row and the text field.
///
/// A tap arms the modifier and the next key spends it. Both views have to
/// see the same latch, or the row lights up for a chord the field never sends.
final class Latch {
  var armed = KeyModifiers()
  var onChange: ((KeyModifiers) -> Void)?

  func toggle(control: Bool) {
    armed = control
      ? KeyModifiers(shift: false, alt: armed.alt, control: !armed.control)
      : KeyModifiers(shift: false, alt: !armed.alt, control: armed.control)
    onChange?(armed)
  }

  func spend() -> KeyModifiers {
    let current = armed
    if current != .none {
      armed = .none
      onChange?(armed)
    }
    return current
  }
}

public struct KeyCapture: View {
  @Environment(\.terminalInputEnabled) private var inputEnabled
  let onInput: (TerminalInput) -> Void
  var latch: Latch
  var active: Bool
  var onFocus: () -> Void
  /// Lines to move the viewport; positive goes back into history.
  var onScroll: (Int32) -> Void
  /// Asked before a wheel is reported to a program that took the mouse.
  /// `true` takes the lines. Shift still scrolls this terminal's history.
  var claimsWheel: (Int32, UInt16, UInt16) -> Bool
  /// How tall a row is, so a trackpad's point deltas become whole lines.
  var lineHeight: CGFloat
  var links: TerminalLinks = .none
  var geometry: CellGeometry = .empty
  var cursorRect: CGRect = .zero
  var onHover: (TerminalLink?) -> Void = { _ in }
  var onSelection: (SelectionUpdate) -> Void = { _ in }
  /// The selection already showing, so a shift-click extends it and ⌘C copies it.
  var selection: GridSelection?
  /// What the far side asked to hear. `off` keeps selection and this app's history.
  /// Scrolled-back history is passed as `off` too: those cells are not the live grid.
  var mouse: MouseTracking = .off

  /// The surface's own: pointing at text needs to know where the cells are.
  init(
    onInput: @escaping (TerminalInput) -> Void, active: Bool, lineHeight: CGFloat,
    onFocus: @escaping () -> Void, onScroll: @escaping (Int32) -> Void,
    claimsWheel: @escaping (Int32, UInt16, UInt16) -> Bool = { _, _, _ in false },
    links: TerminalLinks, geometry: CellGeometry, cursorRect: CGRect,
    onHover: @escaping (TerminalLink?) -> Void,
    onSelection: @escaping (SelectionUpdate) -> Void = { _ in },
    selection: GridSelection? = nil,
    mouse: MouseTracking = .off,
    latch: Latch = Latch()
  ) {
    self.init(
      onInput: onInput, active: active, lineHeight: lineHeight, onFocus: onFocus,
      onScroll: onScroll)
    self.latch = latch
    self.claimsWheel = claimsWheel
    self.links = links
    self.geometry = geometry
    self.cursorRect = cursorRect
    self.onHover = onHover
    self.onSelection = onSelection
    self.selection = selection
    self.mouse = mouse
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
    self.claimsWheel = { _, _, _ in false }
    self.onInput = onInput
    self.latch = Latch()
  }

  public var body: some View {
    #if os(macOS)
      // A wheel is a Mac's way into the history; a phone drags the screen
      // itself, which the surface handles as a gesture.
      MacKeyCapture(
        onInput: onInput, active: active && inputEnabled, onFocus: onFocus,
        onScroll: onScroll, claimsWheel: claimsWheel, lineHeight: lineHeight,
        links: links, geometry: geometry, cursorRect: cursorRect, onHover: onHover,
        onSelection: onSelection, selection: selection, mouse: mouse)
    #else
      // A phone drags the screen itself; the capture view owns that gesture
      // for the same reason the Mac's owns the wheel.
      PhoneKeyCapture(
        onInput: onInput, active: active && inputEnabled, lineHeight: lineHeight,
        onFocus: onFocus, onScroll: onScroll, claimsWheel: claimsWheel, links: links,
        geometry: geometry,
        latch: latch, mouse: mouse)
    #endif
  }
}
