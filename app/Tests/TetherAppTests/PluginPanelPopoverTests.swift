#if os(macOS)
import AppKit
import SwiftUI
import Testing
import Observation
import TetherPluginKit
import TetherUI
@testable import TetherApp

@MainActor private final class PanelWorkspace: PluginWorkspace {
  let id = UUID()
  let title = "Fixture"
  let subtitle = ""
  let symbol = "puzzlepiece.extension"
  let commands: [PluginCommand] = []
  func content() -> AnyView { AnyView(Text("Plugin panel").frame(width: 400, height: 450)) }
  func inspector() -> AnyView { AnyView(EmptyView()) }
  func close() {}
}

@MainActor @Observable private final class PermissionProbe {
  var pending = false
  var allowed = false
}

private struct PermissionHost: View {
  let probe: PermissionProbe
  var body: some View {
    Color.clear.dialog(for: probe.pending ? "network" : nil) { permission in
      Dialog(title: "Fixture", message: permission, actions: [
        Dialog.Action("Allow", role: .confirm) { _ in probe.allowed = true; probe.pending = false },
        .cancel("Cancel") { probe.pending = false },
      ])
    }
  }
}

@MainActor @Suite("Plugin permission presentation", .serialized)
struct PluginPanelPopoverTests {
  @Test func permissionSheetDoesNotDismissThePluginPanel() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    let anchor = PluginPanelPopover.Anchor(frame: NSRect(x: 200, y: 20, width: 40, height: 24))
    let probe = PermissionProbe()
    window.contentView = NSHostingView(rootView: PermissionHost(probe: probe))
    window.contentView?.addSubview(anchor)
    window.makeKeyAndOrderFront(nil)
    defer { anchor.stop(); window.orderOut(nil) }
    anchor.workspace = PanelWorkspace()
    anchor.presented = true
    anchor.updatePresentation()
    #expect(anchor.popover.isShown)
    probe.pending = true
    defer { probe.pending = false }
    for _ in 0..<300 where window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    let sheet = try #require(window.sheets.first)
    try await Task.sleep(for: .milliseconds(250))
    #expect(anchor.popover.isShown, "the permission sheet must not cancel the panel")
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    #expect(anchor.route(click) != nil)
    #expect(anchor.popover.isShown)
    let allow = try #require(button("Allow", in: sheet.contentView!))
    allow.performClick(nil)
    #expect(probe.allowed)
    for _ in 0..<100 where !window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(anchor.popover.isShown)
    let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
    _ = anchor.route(outside)
    #expect(!anchor.popover.isShown)
  }

  private func button(_ title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    for child in view.subviews { if let found = button(title, in: child) { return found } }
    return nil
  }
}
#endif
