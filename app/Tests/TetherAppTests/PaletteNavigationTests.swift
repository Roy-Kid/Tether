#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TetherUI
@testable import TetherApp

extension MacUITests {
@MainActor
@Suite("Unix picker navigation", .serialized)
struct PaletteNavigationTests {
  private func findField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { findField(in: $0) }.first
  }

  @Test("Cmd+1…9 activate current enabled results before workspace bindings", arguments: [false, true])
  func numberedSelection(quickSwitch: Bool) async throws {
    _ = NSApplication.shared
    let state = NumberedPaletteState()
    let window = NumberedPickerWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: NumberedPalette(state: state,
      quickSwitch: quickSwitch))
    let monitor = WorkspaceKeyBindingMonitor.MonitorView()
    window.contentView!.addSubview(monitor)
    monitor.enabled = true
    var workspaceActions = 0
    monitor.handle = { _, _ in workspaceActions += 1; return true }
    window.orderFrontRegardless()
    defer { monitor.stop(); window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(300))
    let field = try #require(findField(in: window.contentView!))
    window.makeFirstResponder(field)
    let editor = try #require(field.currentEditor() as? NSTextView)

    func event(_ key: String, flags: NSEvent.ModifierFlags = .command,
      repeated: Bool = false, target: NSWindow? = nil) throws -> NSEvent {
      try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: (target ?? window).windowNumber, context: nil,
        characters: key, charactersIgnoringModifiers: key, isARepeat: repeated, keyCode: 18))
    }
    #expect(monitor.route(try event("1")) == nil)
    #expect(monitor.route(try event("2")) == nil)
    #expect(monitor.route(try event("9")) == nil)
    #expect(state.chosen == ["item-1", "item-3", "item-10"], "disabled items do not use a number")
    #expect(workspaceActions == 0)
    #expect(PickerShortcuts.handle(try event("1", repeated: true)))
    #expect(state.chosen.count == 3)
    for flags: NSEvent.ModifierFlags in [[], .control, .option, [.command, .shift], [.command, .option]] {
      #expect(!PickerShortcuts.handle(try event("1", flags: flags)))
    }
    #expect(!PickerShortcuts.handle(try event("0")))

    // The focused search editor keeps ordinary numbers, then narrows the list.
    editor.insertText("10", replacementRange: editor.selectedRange())
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.query == "10")
    #expect(monitor.route(try event("1")) == nil)
    #expect(state.chosen.last == "item-10")
    #expect(monitor.route(try event("2")) == nil)
    #expect(state.chosen.count == 4)
    #expect(workspaceActions == 0, "unused numbers stay with the popup")

    state.query = "no matches"
    try await Task.sleep(for: .milliseconds(100))
    #expect(monitor.route(try event("1")) == nil)
    #expect(state.chosen.count == 4)
    editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!PickerShortcuts.handle(try event("1")))
    editor.unmarkText()

    let other = NumberedPickerWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    #expect(!PickerShortcuts.handle(try event("1", target: other)))
    window.beginSheet(other, completionHandler: nil)
    #expect(!PickerShortcuts.handle(try event("1")), "a sheet owns the keyboard over its popup")
    window.endSheet(other)
    other.orderOut(nil)
    window.contentView!.isHidden = true
    #expect(!PickerShortcuts.handle(try event("1")))
    window.contentView!.isHidden = false
    window.contentView = NSView()
    window.contentView!.addSubview(monitor)
    #expect(monitor.route(try event("1")) == nil)
    #expect(workspaceActions == 1, "dismissing the popup restores workspace shortcuts")
  }

  @Test("host numbers follow the displayed grouping and search results")
  func numberedHosts() async throws {
    _ = NSApplication.shared
    let file = temporaryFile("hosts")
    defer { removeDirectory(of: file) }
    let store = HostStore(location: file, secrets: MemorySecrets(), credentials: HostStoreTests.credentials())
    let first = HostStoreTests.host("Alpha")
    let current = HostStoreTests.host("Zulu")
    try #require(store.save(first))
    try #require(store.save(current))
    let savedFirst = try #require(store.listed.first { $0.id == first.id })
    let tabs = TabSet()
    tabs.currentHost = current
    tabs.hostPicker = true
    let window = NumberedPickerWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: HostPicker(tabs: tabs, store: store))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(300))
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
    #expect(PickerShortcuts.handle(key))
    #expect(tabs.intent == .connect(current), "the current host is first even when its label sorts last")
    #expect(!tabs.hostPicker)
    tabs.intent = nil
    tabs.hostPicker = true
    let field = try #require(findField(in: window.contentView!))
    window.makeFirstResponder(field)
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("Alpha", replacementRange: editor.selectedRange())
    try await Task.sleep(for: .milliseconds(100))
    #expect(PickerShortcuts.handle(key))
    #expect(tabs.intent == .connect(savedFirst))
    #expect(!tabs.hostPicker)
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

@MainActor
private final class NumberedPickerWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

@MainActor
@Observable
private final class NumberedPaletteState {
  var query = ""
  var chosen: [String] = []

  var items: [CommandItem] {
    (1...12).map { number in
      let id = "item-\(number)"
      return CommandItem(id: id, title: id, detail: "", enabled: number != 2) {
        self.chosen.append(id)
      }
    }.filter { query.isEmpty || $0.title.contains(query) }
  }
}

private struct NumberedPalette: View {
  @Bindable var state: NumberedPaletteState
  let quickSwitch: Bool

  var body: some View {
    PalettePanel(kind: quickSwitch ? .quickSwitch : .command, query: $state.query,
      items: state.items, listHeight: 200, onCancel: {})
  }
}
#endif
