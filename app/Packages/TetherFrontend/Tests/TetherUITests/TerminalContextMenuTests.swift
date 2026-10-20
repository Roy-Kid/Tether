#if os(macOS)
import AppKit
import Testing
import Tether
@testable import TetherUI

@MainActor
@Suite("Native terminal context menus")
struct TerminalContextMenuTests {
  private func event(shift: Bool = false) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 16, y: 16),
      modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
  }

  @Test("ordinary text has a workspace menu and submenu actions remain live")
  func ordinaryMenu() throws {
    _ = NSApplication.shared
    let view = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    var chosen = false
    view.menuItems = [TerminalMenuItem("Switch Terminal", children: [
      TerminalMenuItem("Shell 2", checked: true) { chosen = true }
    ]), .separator, TerminalMenuItem("Split Right", enabled: false)]
    let menu = try #require(view.menu(for: event()))
    #expect(menu.items.map(\.title) == ["Switch Terminal", "", "Split Right"])
    #expect(menu.items[1].isSeparatorItem)
    #expect(!menu.items[2].isEnabled)
    let submenu = try #require(menu.items[0].submenu)
    #expect(submenu.items[0].state == .on)
    submenu.performActionForItem(at: 0)
    #expect(chosen)
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
