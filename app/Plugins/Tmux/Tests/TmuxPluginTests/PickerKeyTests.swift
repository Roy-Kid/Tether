#if os(macOS)
import AppKit
import SwiftUI
import Testing
import Tether
import TetherPluginKit
@testable import TmuxPlugin

@MainActor
@Suite("Picker keyboard actions", .serialized)
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
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 300),
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
      window.sendEvent(event)
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
  }
}
#endif
