#if os(macOS)

import AppKit
import SwiftUI
import Tether

/// Captures key presses as a terminal needs them.
///
/// SwiftUI's `onKeyPress` reports text and a handful of named keys; a
/// terminal needs the difference between Control-C and "c", between an arrow
/// and the text it would produce, and between F5 and nothing at all. So this
/// drops to an `NSView` and reads `NSEvent` directly.
///
/// It reports a [`TerminalInput`], not bytes. What a key means on the wire
/// depends on modes the *remote* program set, and only the engine knows
/// those — deciding here would be guessing (spec §12).
struct MacKeyCapture: NSViewRepresentable {
  let onInput: (TerminalInput) -> Void
  var active = true
  var onFocus: () -> Void = {}
  var onScroll: (Int32) -> Void = { _ in }
  var lineHeight: CGFloat = 17

  func makeNSView(context: Context) -> KeyCaptureView {
    let view = KeyCaptureView()
    view.onInput = onInput
    view.onFocus = onFocus
    view.onScroll = onScroll
    view.lineHeight = lineHeight
    view.wantsFocus = active
    return view
  }

  func updateNSView(_ view: KeyCaptureView, context: Context) {
    if active && !view.wantsFocus { view.window?.makeFirstResponder(view) }
    view.onInput = onInput
    view.onFocus = onFocus
    view.onScroll = onScroll
    view.lineHeight = lineHeight
    view.wantsFocus = active
  }
}

final class KeyCaptureView: NSView, @MainActor NSTextInputClient {
  var wantsFocus = false
  var onFocus: (() -> Void)?
  private var marked = NSAttributedString()
  var onInput: ((TerminalInput) -> Void)?
  /// Positive goes back into history, matching a wheel pushed away.
  var onScroll: ((Int32) -> Void)?
  /// How tall a row is, so a trackpad's point deltas become lines.
  var lineHeight: CGFloat = 17
  /// Fractional lines left over from the last wheel event.
  private var carried: CGFloat = 0

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if wantsFocus { window?.makeFirstResponder(self) }
  }

  /// Tab and the arrows are taken before the view-loop sees them.
  ///
  /// Without this, Tab moves focus to the next control and an arrow scrolls
  /// a parent — a terminal that cannot send Tab is not a terminal.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Command chords are the application's: ⌘Q, ⌘V and the rest must keep
    // working, and a terminal has nothing to send for them anyway.
    guard !hasMarkedText(), window?.firstResponder === self, !event.modifierFlags.contains(.command)
    else { return false }
    if !event.modifierFlags.intersection([.control, .option]).isEmpty {
    } else if Self.namedKey(for: event) == nil {
      return false
    }

    // Claimed only when there is something to send. Returning true for a
    // key this terminal has no bytes for would swallow it from the rest
    // of the responder chain as well.
    guard let onInput, let input = Self.input(for: event) else { return false }
    onInput(input)
    return true
  }

  /// A wheel or a two-finger swipe reads the history.
  ///
  /// Whole lines only: a terminal's history has no half-rows to stop
  /// between, and a fractional offset would shimmer as it accumulated.
  override func scrollWheel(with event: NSEvent) {
    guard let onScroll else {
      super.scrollWheel(with: event)
      return
    }

    carried += event.hasPreciseScrollingDeltas
      ? event.scrollingDeltaY / lineHeight
      : event.scrollingDeltaY

    let lines = carried.rounded(.towardZero)
    guard lines != 0 else { return }
    carried -= lines
    onScroll(Int32(lines))
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onFocus?()
  }

  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
      super.keyDown(with: event)
      return
    }
    if hasMarkedText() {
      interpretKeyEvents([event])
      return
    }
    if Self.namedKey(for: event) != nil
      || !event.modifierFlags.intersection([.control, .option]).isEmpty
    {
      if let input = Self.input(for: event) { onInput?(input) }
    } else {
      interpretKeyEvents([event])
    }
  }
  @objc func paste(_ sender: Any?) {
    if let text = NSPasteboard.general.string(forType: .string) { onInput?(.paste(text)) }
  }
  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
    marked = NSAttributedString()
    if !text.isEmpty { onInput?(.key(.text(text))) }
  }
  override func insertText(_ string: Any) {
    insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
  }
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
  }
  func unmarkText() { marked = NSAttributedString() }
  func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
  func markedRange() -> NSRange {
    NSRange(location: marked.length == 0 ? NSNotFound : 0, length: marked.length)
  }
  func hasMarkedText() -> Bool { marked.length > 0 }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    window?.convertToScreen(
      convert(NSRect(x: 8, y: bounds.height - 24, width: 1, height: 20), to: nil)) ?? .zero
  }
  override func doCommand(by selector: Selector) {}

  static func input(for event: NSEvent) -> TerminalInput? {
    let flags = event.modifierFlags
    let modifiers = KeyModifiers(
      shift: flags.contains(.shift),
      alt: flags.contains(.option),
      control: flags.contains(.control))

    if let named = namedKey(for: event) {
      return .key(named, modifiers)
    }

    // `charactersIgnoringModifiers` is what a control chord is built from:
    // Control-C arrives with characters "\u{03}" already applied, and
    // encoding that again would send a different byte. The engine applies
    // the chord itself, so it needs the letter.
    let source =
      modifiers.control
      ? event.charactersIgnoringModifiers : event.characters

    guard let text = source, !text.isEmpty else { return nil }

    // Option-as-Meta: macOS turns Option-b into "∫". A terminal wants the
    // base letter with alt set, which is what every other terminal on this
    // platform does.
    if modifiers.alt, let base = event.charactersIgnoringModifiers, !base.isEmpty {
      return .key(.text(base), modifiers)
    }

    return .key(.text(text), modifiers)
  }

  /// The keys that are not text.
  ///
  /// Matched on `keyCode` for the ones AppKit gives no character for, and on
  /// the private-use scalars AppKit invents for the rest.
  private static func namedKey(for event: NSEvent) -> Key? {
    switch event.keyCode {
    case 36, 76: return .enter  // Return and the keypad's Enter
    case 48: return .tab
    case 51: return .backspace
    case 53: return .escape
    case 117: return .delete
    case 115: return .home
    case 119: return .end
    case 116: return .pageUp
    case 121: return .pageDown
    case 126: return .up
    case 125: return .down
    case 123: return .left
    case 124: return .right
    default: break
    }

    guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
      return nil
    }

    switch Int(scalar.value) {
    case NSF1FunctionKey...NSF20FunctionKey:
      return .function(UInt8(Int(scalar.value) - NSF1FunctionKey + 1))
    case NSInsertFunctionKey: return .insert
    case NSDeleteFunctionKey: return .delete
    case NSHomeFunctionKey: return .home
    case NSEndFunctionKey: return .end
    case NSPageUpFunctionKey: return .pageUp
    case NSPageDownFunctionKey: return .pageDown
    default: return nil
    }
  }
}

#endif
