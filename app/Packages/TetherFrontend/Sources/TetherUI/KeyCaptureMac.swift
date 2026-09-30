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
  var links: TerminalLinks = .none
  var geometry: CellGeometry = .empty
  var cursorRect: CGRect = .zero
  var onHover: (TerminalLink?) -> Void = { _ in }
  var onSelection: (SelectionUpdate) -> Void = { _ in }
  var selection: GridSelection?

  func makeNSView(context: Context) -> KeyCaptureView {
    let view = KeyCaptureView()
    apply(to: view)
    return view
  }

  func updateNSView(_ view: KeyCaptureView, context: Context) {
    if active && !view.wantsFocus { view.window?.makeFirstResponder(view) }
    if !active && view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    apply(to: view)
  }

  private func apply(to view: KeyCaptureView) {
    view.onInput = onInput
    view.onFocus = onFocus
    view.onScroll = onScroll
    view.lineHeight = lineHeight
    view.wantsFocus = active
    view.links = links
    view.geometry = geometry
    view.cursorRect = cursorRect
    view.onHover = onHover
    view.onSelection = onSelection
    view.selection = selection
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
  var links: TerminalLinks = .none
  var geometry: CellGeometry = .empty
  /// The terminal caret in top-left-origin surface coordinates.
  var cursorRect: CGRect = .zero {
    didSet {
      if cursorRect != oldValue { inputContext?.invalidateCharacterCoordinates() }
    }
  }
  var onHover: ((TerminalLink?) -> Void)?
  var onSelection: (SelectionUpdate) -> Void = { _ in }
  /// The selection on screen. Shift-click extends its anchor; ⌘C copies it.
  var selection: GridSelection?
  /// The link under the pointer while ⌘ is held.
  private var hovered: TerminalLink?
  /// Where a drag began, and how it chooses text. A click that never moves
  /// stays unarmed, so it clears a selection instead of copying one cell.
  private var dragKind = SelectionKind.character
  private var dragAnchor: GridPoint?
  private var dragHead: GridPoint?
  private var dragArmed = false
  private var dragStart = NSPoint.zero
  /// A few points, under half a cell: a shaky click is not a selection.
  private let dragSlop: CGFloat = 4
  /// A force click opens once per press, not once per pressure change.
  private var forced = false

  override var acceptsFirstResponder: Bool { true }

  // MARK: - Pointing at links
  //
  // A plain click belongs to whatever runs in the terminal — agents and
  // editors turn on mouse reporting — so a link answers only to what a
  // program there cannot ask for: ⌘, a force click, or the context menu.

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    hover(event.modifierFlags.contains(.command) ? link(at: event.locationInWindow) : nil)
  }

  override func flagsChanged(with event: NSEvent) {
    super.flagsChanged(with: event)
    guard let window else { return }
    hover(
      event.modifierFlags.contains(.command)
        ? link(at: window.mouseLocationOutsideOfEventStream) : nil)
  }

  override func mouseExited(with event: NSEvent) {
    if hovered != nil {
      hovered = nil
      onHover?(nil)
    }
    NSCursor.arrow.set()
  }

  override func pressureChange(with event: NSEvent) {
    if event.stage >= 2, !forced, let link = link(at: event.locationInWindow) {
      forced = true
      links.open(link)
    } else if event.stage < 2 {
      forced = false
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let link = link(at: event.locationInWindow), let menu = links.menu(link),
      !menu.items.isEmpty
    else { return nil }
    let built = NSMenu()
    for item in menu.items {
      let entry = ClosureMenuItem(title: item.title, action: item.action)
      entry.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
      built.addItem(entry)
    }
    return built
  }

  private func hover(_ link: TerminalLink?) {
    guard link != hovered else { return }
    hovered = link
    onHover?(link)
    (link == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    discardCursorRects()
    addCursorRect(bounds, cursor: hovered == nil ? .iBeam : .pointingHand)
  }

  /// The link under a point in window coordinates.
  private func link(at location: NSPoint) -> TerminalLink? {
    guard let cell = cell(at: location) else { return nil }
    return links.find(cell.row, cell.column)
  }

  /// Top-left origin, matching the grid. AppKit's own origin is the bottom.
  private func surfacePoint(_ location: NSPoint) -> CGPoint {
    let point = convert(location, from: nil)
    return CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
  }

  private func cell(at location: NSPoint) -> (row: UInt16, column: UInt16)? {
    geometry.cell(at: surfacePoint(location))
  }

  private func clampedCell(at location: NSPoint) -> (row: UInt16, column: UInt16)? {
    geometry.clampedCell(at: surfacePoint(location))
  }

  private func gridPoint(_ cell: (row: UInt16, column: UInt16)) -> GridPoint {
    GridPoint(row: Int(cell.row), column: Int(cell.column))
  }

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
    // Control-Shift-P is the command menu. It must not become terminal bytes.
    if event.modifierFlags.contains(.control),
      event.modifierFlags.contains(.shift),
      event.charactersIgnoringModifiers?.lowercased() == "p"
    {
      return false
    }
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

  override var mouseDownCanMoveWindow: Bool { false }

  /// A parent that scrolls would otherwise keep the wheel. The history is
  /// this view's, and a swipe that moves some outer container instead is a
  /// terminal that cannot be read.
  override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
    axis == .vertical || axis == .horizontal
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
    dragAnchor = nil
    dragHead = nil
    dragArmed = false
    dragKind = .character
    dragStart = event.locationInWindow

    // ⌘ belongs to links. A program in the terminal cannot ask for it, which
    // is why a plain drag is free to select the text instead.
    if event.modifierFlags.contains(.command) {
      if let link = link(at: event.locationInWindow) { links.open(link) }
      return
    }
    guard let cell = cell(at: event.locationInWindow) else { return }
    let point = gridPoint(cell)
    if event.clickCount >= 3 {
      begin(.line, at: point)
    } else if event.clickCount == 2 {
      begin(.word, at: point)
    } else if event.modifierFlags.contains(.shift), let selection {
      dragKind = .character
      dragAnchor = selection.anchor
      dragHead = point
      dragArmed = true
      onSelection(.highlight(.character, selection.anchor, point))
    } else {
      dragAnchor = point
      dragHead = point
    }
  }

  private func begin(_ kind: SelectionKind, at point: GridPoint) {
    dragKind = kind
    dragAnchor = point
    dragHead = point
    dragArmed = true
    onSelection(.highlight(kind, point, point))
  }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor = dragAnchor else { return }
    let moved = hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y)
    if !dragArmed, moved < dragSlop { return }
    guard let cell = clampedCell(at: event.locationInWindow) else { return }
    dragArmed = true
    let head = gridPoint(cell)
    dragHead = head
    onSelection(.highlight(dragKind, anchor, head))
  }

  override func mouseUp(with event: NSEvent) {
    let armed = dragArmed
    let kind = dragKind
    let anchor = dragAnchor
    let head = dragHead
    dragAnchor = nil
    dragHead = nil
    dragArmed = false
    guard armed, let anchor else {
      onSelection(.clear)
      return
    }
    onSelection(.copy(kind, anchor, head ?? anchor))
  }

  /// ⌘C. The menu's Copy item finds this because the view is first responder.
  @objc func copy(_ sender: Any?) {
    guard let selection else { return }
    onSelection(.copyExisting(selection))
  }

  @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(copy(_:)):
      return selection != nil
    case #selector(paste(_:)):
      return NSPasteboard.general.string(forType: .string)?.isEmpty == false
    default:
      return true
    }
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
    actualRange?.pointee = markedRange()
    guard let window else { return .zero }
    var rect = cursorRect
    // AppKit views normally count up from the bottom; terminal rows count down.
    if !isFlipped { rect.origin.y = bounds.height - rect.maxY }
    return window.convertToScreen(convert(rect, to: nil))
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

/// A menu item that runs a closure: a context menu built from a
/// [`LinkMenu`] has no target object to send a selector to.
private final class ClosureMenuItem: NSMenuItem {
  private let run: () -> Void

  init(title: String, action: @escaping () -> Void) {
    run = action
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("not from a nib") }

  @objc private func fire() { run() }
}

#endif
