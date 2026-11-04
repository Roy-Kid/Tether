#if os(macOS)
import AppKit
import Testing
import TetherTestSupport
@testable import TetherApp

@MainActor
@Suite("Unix text editing", .serialized, .appKitEventLoop)
struct UnixTextEditingTests {
  private func fixture(_ text: String) -> (NSWindow, NSTextView) {
    _ = NSApplication.shared
    let window = EditingTestWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let editor = NSTextView(frame: window.contentView!.bounds)
    editor.isRichText = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.allowsUndo = true
    editor.string = text
    window.contentView!.addSubview(editor)
    window.makeFirstResponder(editor)
    return (window, editor)
  }

  private func key(_ letter: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
    let characters: String
    if flags.contains(.control), let scalar = letter.uppercased().unicodeScalars.first,
      (64...95).contains(scalar.value) { characters = String(UnicodeScalar(scalar.value & 31)!) }
    else { characters = letter }
    return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: letter, isARepeat: false, keyCode: 0))
  }

  @Test("word movement, selection and deletion use native Unicode-aware editing")
  func words() throws {
    let (window, editor) = fixture("alpha beta")
    editor.setSelectedRange(NSRange(location: 10, length: 0))
    #expect(UnixTextEditing.route(try key("b", .option, in: window)) == nil)
    #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
    #expect(UnixTextEditing.route(try key("f", [.option, .shift], in: window)) == nil)
    #expect(editor.selectedRange() == NSRange(location: 6, length: 4))
    editor.setSelectedRange(NSRange(location: 6, length: 0))
    #expect(UnixTextEditing.route(try key("d", .option, in: window)) == nil)
    #expect(editor.string == "alpha ")
    #expect(UnixTextEditing.route(try key("w", .control, in: window)) == nil)
    #expect(editor.string.isEmpty)

    editor.string = "alpha beta"
    editor.setSelectedRange(NSRange(location: 6, length: 0))
    #expect(UnixTextEditing.route(try key("u", .control, in: window)) == nil)
    #expect(editor.string == "beta")
  }

  @Test("composition, read-only content and non-text responders are not intercepted")
  func focusBoundaries() throws {
    let (window, editor) = fixture("draft")
    let event = try key("w", .control, in: window)
    editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(UnixTextEditing.route(event) === event)
    editor.unmarkText()
    editor.isEditable = false
    #expect(UnixTextEditing.route(event) === event)
    window.makeFirstResponder(nil)
    #expect(UnixTextEditing.route(event) === event)
  }

}

private final class EditingTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
#endif
