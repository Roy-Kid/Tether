import SwiftUI
import Tether

public struct PluginMetadata: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let symbol: String
  public let summary: String
  public init(id: String, name: String, symbol: String, summary: String) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.summary = summary
  }
}

@MainActor
public struct PluginCommand: Identifiable {
  public let id: String
  public let title: String
  public let symbol: String
  public let action: () -> Void
  public init(id: String, title: String, symbol: String, action: @escaping () -> Void) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.action = action
  }
}

/// An extension owns its content; the host owns its tab and lifetime.
@MainActor
public protocol PluginWorkspace: AnyObject, Identifiable where ID == UUID {
  var id: UUID { get }
  var title: String { get }
  var subtitle: String { get }
  var symbol: String { get }
  var commands: [PluginCommand] { get }
  func content() -> AnyView
  func inspector() -> AnyView
  func close()
}

@MainActor
public struct PluginContext {
  public let connection: RemoteConnection
  public let hostLabel: String
  public let hostID: UUID
  public let openWorkspace: (any PluginWorkspace) -> Void
  /// Reauthentication belongs to the host, never the plugin. No credentials cross this API.
  public let reconnect: () async throws -> RemoteConnection
  public init(
    connection: RemoteConnection, hostLabel: String, hostID: UUID,
    openWorkspace: @escaping (any PluginWorkspace) -> Void,
    reconnect: @escaping () async throws -> RemoteConnection
  ) {
    self.connection = connection
    self.hostLabel = hostLabel
    self.hostID = hostID
    self.openWorkspace = openWorkspace
    self.reconnect = reconnect
  }
}

@MainActor
public protocol TetherPlugin: AnyObject {
  var metadata: PluginMetadata { get }
  func activate()
  func deactivate()
  func launch(in context: PluginContext)
  func settings() -> AnyView
}
extension TetherPlugin {
  public func activate() {}
  public func deactivate() {}
  public func settings() -> AnyView { AnyView(Text("No additional settings")) }
}

/// Namespaced, nonsecret preferences. Plugins never receive the host's credential store.
public struct PluginPreferences {
  private let prefix: String
  private let defaults: UserDefaults
  public init(pluginID: String, defaults: UserDefaults = .standard) {
    prefix = "plugin.\(pluginID)."
    self.defaults = defaults
  }
  public func string(for key: String) -> String? { defaults.string(forKey: prefix + key) }
  public func set(_ value: String?, for key: String) { defaults.set(value, forKey: prefix + key) }
}

@MainActor @Observable
public final class PluginRegistry {
  public private(set) var plugins: [any TetherPlugin] = []
  public private(set) var disabled: Set<String>
  private let defaults: UserDefaults
  public var onDisable: ((String) -> Void)?
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    disabled = Set(defaults.stringArray(forKey: "disabledPlugins") ?? [])
  }
  public func register(_ plugin: any TetherPlugin) {
    precondition(!plugins.contains { $0.metadata.id == plugin.metadata.id }, "Duplicate plugin ID")
    plugins.append(plugin)
    if isEnabled(plugin.metadata.id) { plugin.activate() }
  }
  public func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }
  public func setEnabled(_ enabled: Bool, id: String) {
    guard let plugin = plugins.first(where: { $0.metadata.id == id }), enabled != isEnabled(id)
    else { return }
    if enabled {
      disabled.remove(id)
      plugin.activate()
    } else {
      disabled.insert(id)
      onDisable?(id)
      plugin.deactivate()
    }
    defaults.set(Array(disabled).sorted(), forKey: "disabledPlugins")
  }
}
