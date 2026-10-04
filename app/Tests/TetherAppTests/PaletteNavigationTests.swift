#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import TetherApp

extension MacUITests {
@MainActor
@Suite("Unix picker navigation", .serialized)
struct PaletteNavigationTests {
  private func findField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { findField(in: $0) }.first
  }

  @Test("Ctrl+P/N navigate results while Ctrl+B/F edit the query")
  func navigation() async throws {
    _ = NSApplication.shared
    var query = ""
    var chosen: [String] = []
    var cancelled = false
    let items = ["first", "disabled", "last"].map { id in
      CommandItem(id: id, title: id, detail: "", enabled: id != "disabled") { chosen.append(id) }
    }
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: PalettePanel(kind: .command,
      query: Binding(get: { query }, set: { query = $0 }), items: items, listHeight: 200,
      onCancel: { cancelled = true }))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(300))
    let field = try #require(findField(in: window.contentView!))
    window.makeFirstResponder(field)
    let editor = try #require(field.currentEditor() as? NSTextView)

    func press(_ characters: String, base: String? = nil, code: UInt16,
               flags: NSEvent.ModifierFlags = []) async throws {
      let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: base ?? characters,
        isARepeat: false, keyCode: code))
      if let event = UnixTextEditing.route(event) { window.sendEvent(event) }
      try await Task.sleep(for: .milliseconds(50))
    }

    try await press("\u{0e}", base: "n", code: 45, flags: .control)
    try await press("\r", code: 36)
    #expect(chosen == ["last"])
    try await press("\u{10}", base: "p", code: 35, flags: .control)
    try await press("\r", code: 36)
    #expect(chosen == ["last", "first"])

    // Ordinary typing must not navigate, and the text editor retains its
    // native Control bindings instead of changing the selected result.
    try await press("n", code: 45)
    #expect(query == "n")
    try await press("p", code: 35)
    #expect(query == "np")
    editor.setSelectedRange(NSRange(location: 1, length: 0))
    try await press("\u{02}", base: "b", code: 11, flags: .control)
    #expect(editor.selectedRange().location == 0)
    try await press("\u{06}", base: "f", code: 3, flags: .control)
    #expect(editor.selectedRange().location == 1)
    try await press("\u{01}", base: "a", code: 0, flags: .control)
    #expect(editor.selectedRange().location == 0)
    try await press("\u{05}", base: "e", code: 14, flags: .control)
    #expect(editor.selectedRange().location == 2)
    try await press("\r", code: 36)
    #expect(chosen.last == "first")

    try await press("\u{f701}", code: 125)
    try await press("\r", code: 36)
    #expect(chosen.last == "last")

    try await press("\u{f729}", code: 115)
    try await press("\u{0d}", base: "m", code: 46, flags: .control)
    #expect(chosen.last == "first")
    try await press("\u{f72b}", code: 119)
    try await press("\u{0a}", base: "j", code: 38, flags: .control)
    #expect(chosen.last == "last")
    try await press("v", code: 9, flags: .option)
    try await press("\r", code: 36)
    #expect(chosen.last == "first")
    try await press("\u{16}", base: "v", code: 9, flags: .control)
    try await press("\r", code: 36)
    #expect(chosen.last == "last")
    try await press("\u{07}", base: "g", code: 5, flags: .control)
    #expect(cancelled)
  }
}
}
#endif
