#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TetherTestSupport
import Tether
import TetherPluginKit
import TetherUI
@testable import TmuxPlugin

@MainActor
@Suite("Picker keyboard actions", .serialized, .appKitEventLoop)
struct PickerKeyTests {
  @Test("keyboard navigation, hierarchy, confirmation and cancellation work without a server")
  func actions() async throws {
    _ = NSApplication.shared
    var shells = 0
    var dismissed = 0
    var sheets = 0
    let tab = TabContext(id: UUID(), plugin: PluginContext(connection: nil, hostLabel: "test",
      hostID: UUID(), openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: { dismissed += 1 }, present: { _ in sheets += 1 },
      dismissSheet: {}, newShell: { shells += 1 })
    let model = TmuxTab(tab: tab, owner: { _ in nil }, onClose: {})
    model.sessions = [TmuxSessionInfo(id: "$1", name: "test", attached: false, windows: [
      TmuxListedWindow(id: 1, index: 0, name: "one", active: true, panes: 1),
      TmuxListedWindow(id: 2, index: 1, name: "two", active: false, panes: 1),
    ])]
    let window = PickerTestWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: TmuxPicker(model: model))
    window.orderFrontRegardless()
    defer { window.orderOut(nil); model.close() }
    try await Task.sleep(for: .milliseconds(400))

    func press(_ characters: String, base: String? = nil, code: UInt16,
               flags: NSEvent.ModifierFlags = []) async throws {
      let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: base ?? characters,
        isARepeat: false, keyCode: code))
      if !PickerShortcuts.handle(event) { window.sendEvent(event) }
      try await Task.sleep(for: .milliseconds(70))
    }

    try await press("\u{0e}", base: "n", code: 45, flags: .control)
    try await press("\u{0d}", base: "m", code: 46, flags: .control)
    #expect(shells == 1)
    #expect(dismissed == 1)
    try await press("\u{0e}", base: "n", code: 45, flags: .control)
    try await press("\u{06}", base: "f", code: 3, flags: .control)
    try await press("\u{07}", base: "g", code: 5, flags: .control)
    #expect(dismissed == 1, "the first cancel returns from the window level")
    try await press("\u{07}", base: "g", code: 5, flags: .control)
    #expect(dismissed == 2)
    try await press("\u{f72b}", code: 119)
    try await press("\u{0a}", base: "j", code: 38, flags: .control)
    #expect(sheets == 0)
    #expect(model.namingSession)
    try await press("\u{1b}", code: 53)
    #expect(!model.namingSession)

    try await press("2", code: 19, flags: .command)
    #expect(shells == 2)
    #expect(dismissed == 3)
    try await press("3", code: 20, flags: .command)
    try await press("1", code: 18, flags: .command)
    #expect(dismissed == 3, "Cmd+1 returns to the session list from the window submenu")
    try await press("4", code: 21, flags: .command)
    #expect(sheets == 0)
    #expect(model.namingSession, "numbering follows the current submenu")
    model.busy = true
    try await Task.sleep(for: .milliseconds(70))
    try await press("2", code: 19, flags: .command)
    #expect(shells == 2, "busy destinations cannot be activated")
  }

  @Test("a new session's name takes the keyboard in this window")
  func newSessionNameIsFocused() async throws {
    _ = NSApplication.shared
    let tab = TabContext(id: UUID(), plugin: PluginContext(connection: nil, hostLabel: "test",
      hostID: UUID(), openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
    let model = TmuxTab(tab: tab, owner: { _ in nil }, onClose: {})
    model.sessions = [TmuxSessionInfo(id: "$1", name: "test", attached: false, windows: [
      TmuxListedWindow(id: 1, index: 0, name: "one", active: true, panes: 1),
    ])]
    let window = PickerTestWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: TmuxPicker(model: model))
    window.orderFrontRegardless()
    defer { window.orderOut(nil); model.close() }
    try await Task.sleep(for: .milliseconds(300))

    try await press("\u{f72b}", code: 119, in: window)
    try await press("\u{0a}", base: "j", code: 38, flags: .control, in: window)
    #expect(model.namingSession)

    let editor = try await focusedEditor(in: window)
    #expect(editor.string == "untitled")
    #expect(editor.selectedRange().length == (editor.string as NSString).length)
    editor.insertText("z", replacementRange: editor.selectedRange())
    #expect(editor.string == "z")
  }

  @Test("ending a session asks on the window that shows the list")
  func endSessionAsksOnThisWindow() async throws {
    _ = NSApplication.shared
    let tab = TabContext(id: UUID(), plugin: PluginContext(connection: nil, hostLabel: "test",
      hostID: UUID(), openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
    let model = TmuxTab(tab: tab, owner: { _ in nil }, onClose: {})
    let session = TmuxSessionInfo(id: "$1", name: "dev", attached: false, windows: [
      TmuxListedWindow(id: 1, index: 0, name: "shell", active: true, panes: 1),
    ])
    model.sessions = [session]
    // Another window is the one AppKit would pick with no anchor: it is main.
    let other = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    other.orderFrontRegardless()
    other.makeMain()
    let window = PickerTestWindow(contentRect: NSRect(x: -3600, y: -4000, width: 300, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: TmuxPicker(model: model))
    window.orderFrontRegardless()
    defer {
      model.sessionToEnd = nil
      model.windowToEnd = nil
      window.contentView = nil
      window.orderOut(nil)
      other.orderOut(nil)
      model.close()
    }
    try await Task.sleep(for: .milliseconds(300))

    model.sessionToEnd = session
    try await settle { window.attachedSheet != nil }
    #expect(other.attachedSheet == nil)
    let sheet = try #require(window.attachedSheet?.contentView)
    let cancel = try #require(button("Cancel", in: sheet))
    cancel.performClick(nil)
    try await settle { window.attachedSheet == nil && model.sessionToEnd == nil }

    let listed = try #require(model.windows(for: session).first)
    model.windowToEnd = listed
    try await settle { window.attachedSheet != nil }
    #expect(other.attachedSheet == nil)
    let windowSheet = try #require(window.attachedSheet?.contentView)
    let cancelWindow = try #require(button("Cancel", in: windowSheet))
    cancelWindow.performClick(nil)
    try await settle { window.attachedSheet == nil && model.windowToEnd == nil }
  }

  @Test("renaming a session edits the row instead of asking")
  func sessionRenameIsInline() async throws {
    _ = NSApplication.shared
    let tab = TabContext(id: UUID(), plugin: PluginContext(connection: nil, hostLabel: "test",
      hostID: UUID(), openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
    let model = TmuxTab(tab: tab, owner: { _ in nil }, onClose: {})
    let session = TmuxSessionInfo(id: "$1", name: "dev", attached: false, windows: [
      TmuxListedWindow(id: 1, index: 0, name: "shell", active: true, panes: 1),
    ])
    model.sessions = [session]
    let window = PickerTestWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: TmuxPicker(model: model))
    window.orderFrontRegardless()
    defer { window.orderOut(nil); model.close() }
    try await Task.sleep(for: .milliseconds(300))
    model.renaming = .session(session)
    try await Task.sleep(for: .milliseconds(300))
    let content = try #require(window.contentView)
    let field = try #require(textField(in: content))
    #expect(field.stringValue == "dev")
    window.makeFirstResponder(field.currentEditor() ?? field)
    let escape = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    window.sendEvent(escape)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.renaming == nil)
  }

  private func press(_ characters: String, base: String? = nil, code: UInt16,
    flags: NSEvent.ModifierFlags = [], in window: NSWindow) async throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: base ?? characters,
      isARepeat: false, keyCode: code))
    if !PickerShortcuts.handle(event) { window.sendEvent(event) }
    try await Task.sleep(for: .milliseconds(70))
  }

  private func focusedEditor(in window: NSWindow) async throws -> NSTextView {
    var editor: NSTextView?
    for _ in 0..<50 {
      editor = window.firstResponder as? NSTextView
      if editor != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    return try #require(editor)
  }

  private func settle(until condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
  }

  private func button(_ title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    return view.subviews.lazy.compactMap { button(title, in: $0) }.first
  }

  private func textField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { textField(in: $0) }.first
  }
}

@MainActor
private final class PickerTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
#endif
