#if os(macOS)
import AppKit
import Testing
@testable import TetherApp

@MainActor
@Suite("Unix text editing", .serialized)
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

  @Test("native delete, kill, yank, transpose and undo remain available")
  func nativeEditing() throws {
    let (window, editor) = fixture("abc def")
    editor.setSelectedRange(NSRange(location: 3, length: 0))
    for letter in ["h", "d"] {
      let event = try key(letter, .control, in: window)
      #expect(UnixTextEditing.route(event) === event)
      editor.keyDown(with: event)
    }
    #expect(editor.string == "abdef")
    editor.keyDown(with: try key("k", .control, in: window))
    #expect(editor.string == "ab")
    editor.keyDown(with: try key("y", .control, in: window))
    #expect(editor.string == "abdef")
    editor.keyDown(with: try key("t", .control, in: window))
    #expect(editor.string == "abdfe")
    editor.breakUndoCoalescing()
    editor.undoManager?.removeAllActions()
    editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.string == "abdfe!")
    #expect(UnixTextEditing.route(try key("_", [.control, .shift], in: window)) == nil)
    #expect(editor.string == "abdfe")
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    editor.keyDown(with: try key("F", [.control, .shift], in: window))
    #expect(editor.selectedRange() == NSRange(location: 0, length: 1))
    for letter in ["a", "x", "c", "v", "z"] {
      let event = try key(letter, .command, in: window)
      #expect(UnixTextEditing.route(event) === event, "native clipboard and undo keys remain native")
    }
  }

  @Test("cancel, confirm and focus aliases re-enter standard responder handling")
  func actions() throws {
    let (window, _) = fixture("draft")
    for (letter, code) in [("g", UInt16(53)), ("m", 36), ("j", 36), ("i", 48)] {
      let event = try #require(UnixTextEditing.route(try key(letter, .control, in: window)))
      #expect(event.keyCode == code)
      #expect(event.modifierFlags.isEmpty)
    }
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

  @Test("workspace overrides win, while Settings-style monitors still enable native editing")
  func routing() throws {
    let (window, editor) = fixture("alpha beta")
    editor.setSelectedRange(NSRange(location: 10, length: 0))
    let monitor = WorkspaceKeyBindingMonitor.MonitorView()
    window.contentView!.addSubview(monitor)
    defer { monitor.stop() }
    monitor.enabled = true
    monitor.textEditingEnabled = true
    monitor.handle = { _, _ in true }
    let event = try key("w", .control, in: window)
    #expect(monitor.route(event) == nil)
    #expect(editor.string == "alpha beta")
    monitor.enabled = false
    #expect(monitor.route(event) == nil)
    #expect(editor.string == "alpha ")
    let (other, _) = fixture("other")
    let unrelated = try key("w", .control, in: other)
    #expect(monitor.route(unrelated) === unrelated)
    window.addChildWindow(other, ordered: .above)
    defer { window.removeChildWindow(other) }
    let childEditor = try #require(other.firstResponder as? NSTextView)
    childEditor.setSelectedRange(NSRange(location: 5, length: 0))
    monitor.enabled = true
    #expect(monitor.route(unrelated) == nil)
    #expect(childEditor.string.isEmpty, "child windows get editing aliases without workspace commands")
  }
}

private final class EditingTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
#endif
