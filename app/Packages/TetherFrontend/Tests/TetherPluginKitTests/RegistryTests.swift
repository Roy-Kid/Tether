import Foundation
import SwiftUI
import Testing
import Tether

@testable import TetherPluginKit

@MainActor
private final class ExamplePlugin: TetherPlugin {
  let metadata = PluginMetadata(
    id: "test.example", name: "Example", symbol: "star", summary: "Test extension")
  var starts = 0
  var tabIndicators: [PluginTabIndicator] = []
  var tabSymbols: [PluginTabSymbol] = []
  var stops = 0
  func activate() { starts += 1 }
  func deactivate() { stops += 1 }
  func launch(in context: PluginContext) { context.openWorkspace(ExampleWorkspace()) }
}
@MainActor
private final class ExampleWorkspace: PluginWorkspace {
  let id = UUID()
  let title = "Example"
  let subtitle = "Independent extension"
  let symbol = "star"
  var invoked = false
  var closed = false
  var commands: [PluginCommand] {
    [
      PluginCommand(id: "example.action", title: "Run", symbol: "play") { [weak self] in
        self?.invoked = true
      }
    ]
  }
  func content() -> AnyView { AnyView(Text(title)) }
  func inspector() -> AnyView { AnyView(Text(subtitle)) }
  func close() { closed = true }
}

@Test @MainActor
func disableReleasesWorkspacesAndPersistsWithoutChangingHost() {
  let name = "TetherTests.\(UUID())"
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let registry = PluginRegistry(defaults: defaults)
  let plugin = ExamplePlugin()
  let workspace = ExampleWorkspace()
  registry.register(plugin)
  #expect(plugin.starts == 1)
  workspace.commands[0].action()
  #expect(workspace.invoked)
  registry.onDisable = { id in if id == plugin.metadata.id { workspace.close() } }
  registry.setEnabled(false, id: plugin.metadata.id)
  #expect(workspace.closed)
  #expect(plugin.stops == 1)
  registry.setEnabled(false, id: plugin.metadata.id)
  #expect(plugin.stops == 1)
  let restored = PluginRegistry(defaults: defaults)
  let other = ExamplePlugin()
  restored.register(other)
  #expect(other.starts == 0)
  restored.setEnabled(true, id: other.metadata.id)
  #expect(other.starts == 1)
}

@MainActor
private final class MarkPlugin: TetherPlugin {
  let metadata = PluginMetadata(
    id: "test.marks", name: "Marks", symbol: "circle", summary: "Marks")
  var onMarks: (@MainActor () -> Void)?
  func launch(in context: PluginContext) {}
  func observeTabMarks(_ notify: @escaping @MainActor () -> Void) { onMarks = notify }
}

@Test
func preferenceNamespacesDoNotOverlap() {
  let name = "TetherTests.\(UUID())"
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let first = PluginPreferences(pluginID: "first", defaults: defaults)
  let second = PluginPreferences(pluginID: "second", defaults: defaults)
  first.set("A", for: "mode")
  second.set("B", for: "mode")
  #expect(first.string(for: "mode") == "A")
  #expect(second.string(for: "mode") == "B")
}

@MainActor
private final class ExampleTabPlugin: TabPlugin {
  let metadata = PluginMetadata(
    id: "test.tab", name: "Tab", symbol: "star", summary: "Test tab extension")
  let accessory = TabAccessory(symbol: "star", name: "tab things")
  var attached: [UUID] = []
  func attach(to tab: TabContext) -> any TabAttachment {
    attached.append(tab.id)
    return ExampleAttachment()
  }
}
@MainActor
private final class ExampleAttachment: TabAttachment {
  let isShowing = false
  let subtitle = ""
  let isDisconnected = false
  let closeNote: String? = nil
  var commands: [PluginCommand] { [] }
  func content() -> AnyView { AnyView(EmptyView()) }
  func inspector() -> AnyView { AnyView(EmptyView()) }
  func accessoryContent() -> AnyView { AnyView(EmptyView()) }
  func connectionChanged(_ connection: RemoteConnection) {}
  func close() {}
}

/// A tab plugin is reached through its accessory. Launching it the way a
/// workspace plugin is launched must open nothing, or the host would get a
/// workspace tab it never asked for.
@Test @MainActor
func aTabPluginOpensNoWorkspace() {
  let plugin = ExampleTabPlugin()
  var opened = 0
  plugin.launch(
    in: PluginContext(
      connection: nil, hostLabel: "", hostID: UUID(),
      openWorkspace: { _ in opened += 1 }, reconnect: { throw CancellationError() }))
  #expect(opened == 0)
  #expect(plugin.attached.isEmpty)
  let registry = PluginRegistry(defaults: UserDefaults(suiteName: "TetherTests.\(UUID())")!)
  registry.register(plugin)
  #expect(registry.plugins.first is any TabPlugin, "the host finds tab plugins by conformance")
}

/// Two plugins' offers for one link read as one menu, and the link is there
/// if either finds it.
@Test @MainActor
func offersForALinkCombine() async {
  var opened: [String] = []
  let first = LinkActions(
    open: { opened.append("first") },
    commands: [PluginCommand(id: "a", title: "A", symbol: "a.circle") {}],
    exists: { false })
  let second = LinkActions(
    open: { opened.append("second") },
    commands: [PluginCommand(id: "b", title: "B", symbol: "b.circle") {}],
    exists: { true })
  let combined = LinkActions.combining([first, second])!
  combined.open?()
  #expect(opened == ["first"])
  #expect(combined.commands.map(\.title) == ["A", "B"])
  #expect(await combined.exists?() == true)
  #expect(LinkActions.combining([]) == nil)
}

@Test @MainActor
func aMarkOnAnyOfSeveralTerminalsFollowsTheReportingPluginsOrder() {
  let name = "TetherIndicatorsAnyOf.\(UUID())"
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let registry = PluginRegistry(defaults: defaults)
  let plugin = ExamplePlugin()
  let first = PluginTerminalIdentity(host: "studio", terminal: "/dev/ttys004")
  let second = PluginTerminalIdentity(host: "studio", terminal: "/dev/ttys009")
  // The plugin's array is its priority: the job it lists first wins.
  plugin.tabIndicators = [
    .init(target: second, color: 0xFF9F0A, label: "Needs you"),
    .init(target: first, color: 0x0A84FF, label: "Running"),
  ]
  registry.register(plugin)
  #expect(registry.tabIndicator(onAnyOf: [first, second])?.label == "Needs you")
  #expect(registry.tabIndicator(onAnyOf: [first])?.label == "Running")
  // `ps` and a pty name spell one device two ways.
  #expect(registry.tabIndicator(onAnyOf: [.init(host: "studio", terminal: "s004")])?.label == "Running")
  #expect(registry.tabIndicator(onAnyOf: [.init(host: "lab", terminal: first.terminal)]) == nil)
  #expect(registry.tabIndicator(onAnyOf: []) == nil)
  registry.setEnabled(false, id: plugin.metadata.id)
  #expect(registry.tabIndicator(onAnyOf: [first, second]) == nil)
}
