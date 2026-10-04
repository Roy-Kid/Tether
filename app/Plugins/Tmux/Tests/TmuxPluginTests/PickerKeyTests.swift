#if os(macOS)
import AppKit
import SwiftUI
import Testing
import Tether
import TetherPluginKit
import TetherUI
@testable import TmuxPlugin

@MainActor
@Suite("Picker keyboard actions", .serialized)
struct PickerKeyTests {
  private func field(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { field(in: $0) }.first
  }

  @Test("new-session input keeps its width when empty, long and resized")
  func createInputLayout() async throws {
    _ = NSApplication.shared
    let tab = TabContext(id: UUID(), plugin: PluginContext(connection: nil, hostLabel: "test",
      hostID: UUID(), openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
    let model = TmuxTab(tab: tab, owner: { _ in nil }, onClose: {})
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000,
      width: UIStyle.menuWidth, height: UIStyle.menuHeight),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: CreateTmuxSheet(model: model, onCancel: {}, onCreate: {}))
    window.orderFrontRegardless()
    defer { window.orderOut(nil); model.close() }
    for text in ["", String(repeating: "session", count: 40)] {
      model.draftName = text
      for width in [UIStyle.menuWidth, UIStyle.menuWidth + 200, UIStyle.menuWidth] {
        window.setContentSize(NSSize(width: width, height: UIStyle.menuHeight))
        try await Task.sleep(for: .milliseconds(200))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let input = try #require(field(in: content))
        #expect(input.bounds.width >= 80)
        #expect(input.bounds.height >= 14)
        #expect(input.visibleRect.width >= 80)
      }
    }
  }

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
    #expect(sheets == 1)

    try await press("2", code: 19, flags: .command)
    #expect(shells == 2)
    #expect(dismissed == 3)
    try await press("3", code: 20, flags: .command)
    try await press("1", code: 18, flags: .command)
    #expect(dismissed == 3, "Cmd+1 returns to the session list from the window submenu")
    try await press("4", code: 21, flags: .command)
    #expect(sheets == 2, "numbering follows the current submenu")
    model.busy = true
    try await Task.sleep(for: .milliseconds(70))
    try await press("2", code: 19, flags: .command)
    #expect(shells == 2, "busy destinations cannot be activated")
  }
}

@MainActor
private final class PickerTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
#endif
