#if os(macOS)
import AppKit
import SwiftUI
import Foundation
import Testing
import Tether
import TetherPluginKit
@testable import TetherApp
import struct TetherApp.Host

@MainActor private final class MarkPlugin: TetherPlugin {
  let metadata = PluginMetadata(id: "test.marks", name: "Marks", symbol: "circle.fill", summary: "")
  var tabIndicators: [PluginTabIndicator] = []
  func activate() {}
  func deactivate() { tabIndicators = [] }
  func launch(in context: PluginContext) {}
}

@MainActor @Suite("Tab indicator rendering", .serialized)
struct TabIndicatorTests {
  @Test(.enabled(if: TerminalSession.isLocalAvailable))
  func marksFollowActualTerminalIdentity() async throws {
    _ = NSApplication.shared
    let tabs = TabSet()
    let shell = SessionTab(host: .local, password: "", known: tabs.known, name: "Build")
    tabs.adopt(shell)
    defer { tabs.closeAll() }
    _ = try await shell.connectionReady()
    let identity = try #require(shell.pluginTerminalIdentity)
    let suite = "TetherTabMarks.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let registry = PluginRegistry(defaults: defaults)
    let plugin = MarkPlugin()
    registry.register(plugin)
    plugin.tabIndicators = [.init(target: identity, color: 0x0A84FF, label: "Running")]
    #expect(registry.tabIndicator(for: identity)?.label == "Running")
    if let prefix = ProcessInfo.processInfo.environment["TETHER_TAB_INDICATOR_SNAPSHOT"] {
      for layout in [TabLayout.horizontal, .vertical] {
        let size = layout == .horizontal ? NSSize(width: 640, height: 42) : NSSize(width: 220, height: 160)
        let content = WorkspaceTabBar(tabs: tabs, registry: registry, layout: layout, onClose: { _ in })
          .frame(width: size.width, height: size.height)
          .environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let data = try #require(image.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(prefix)-\(layout == .horizontal ? "horizontal" : "vertical").png"))
      }
    }
    registry.setEnabled(false, id: plugin.metadata.id)
    #expect(registry.tabIndicator(for: identity) == nil)
  }
}
#endif
