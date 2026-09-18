import Foundation
import SwiftUI
import Testing

@testable import TetherPluginKit

@MainActor
private final class ExamplePlugin: TetherPlugin {
  let metadata = PluginMetadata(
    id: "test.example", name: "Example", symbol: "star", summary: "Test extension")
  var starts = 0
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
