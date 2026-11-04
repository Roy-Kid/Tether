#if os(macOS)
import AppKit
import Testing
import TetherTestSupport
import Tether
@testable import TetherUI

@MainActor
@Suite("Native terminal context menus", .appKitEventLoop)
struct TerminalContextMenuTests {
  private func event(shift: Bool = false) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 16, y: 16),
      modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
  }

  @Test("mouse reporting keeps ordinary right clicks; Shift opens the app menu", arguments: [MouseTracking.clicks, .drag, .any])
  func mouseOwnership(tracking: MouseTracking) throws {
    _ = NSApplication.shared
    let view = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    view.mouse = tracking
    view.menuItems = [TerminalMenuItem("New Terminal") {}]
    #expect(view.menu(for: try event()) == nil)
    #expect(view.menu(for: try event(shift: true))?.items.first?.title == "New Terminal")
  }
}
#endif
