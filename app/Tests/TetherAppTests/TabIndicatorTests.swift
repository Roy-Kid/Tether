#if os(macOS)
import AppKit
import SwiftUI
import Foundation
import Testing
import TetherTestSupport
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

/// A tab plugin showing another tty in this tab, as tmux shows a pane.
@MainActor private final class PaneAttachment: TabAttachment {
  var shownTerminals: [String] = []
  var isShowing: Bool { false }
  var subtitle: String { "" }
  var isDisconnected: Bool { false }
  var closeNote: String? { nil }
  var commands: [PluginCommand] { [] }
  func content() -> AnyView { AnyView(EmptyView()) }
  func inspector() -> AnyView { AnyView(EmptyView()) }
  func accessoryContent() -> AnyView { AnyView(EmptyView()) }
  func connectionChanged(_ connection: RemoteConnection) {}
  func close() {}
}

@MainActor @Suite("Tab indicator rendering", .serialized, .appKitEventLoop)
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
    #expect(registry.indicator(on: shell)?.label == "Running")
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
    // A pane the tab is showing marks the tab too, and the same lookup
    // answers a plugin asking for that pane alone.
    let pane = "/dev/ttys999"
    plugin.tabIndicators = [.init(
      target: .init(host: identity.host, terminal: pane), color: 0xFF9F0A, label: "Needs you")]
    #expect(registry.indicator(on: shell) == nil)
    let attachment = PaneAttachment()
    attachment.shownTerminals = [pane]
    shell.attach(attachment, for: "test.panes")
    #expect(registry.indicator(on: shell)?.label == "Needs you")
    #expect(registry.indicator(on: shell, terminals: [pane])?.label == "Needs you")
    #expect(registry.indicator(on: shell, terminals: []) == nil)
    registry.setEnabled(false, id: plugin.metadata.id)
    #expect(registry.indicator(on: shell) == nil)
  }
}
#endif
