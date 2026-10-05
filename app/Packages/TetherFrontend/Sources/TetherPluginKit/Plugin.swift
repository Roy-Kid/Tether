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

/// One weighted status band. Colours are sRGB 0xRRGGBB values so plugins can
/// contribute without importing a UI framework.
public struct PluginStatusSegment: Identifiable, Sendable, Hashable {
  public let id: String
  public let color: UInt32
  public let weight: Double

  public init(id: String, color: UInt32, weight: Double) {
    self.id = id
    self.color = color
    self.weight = max(0, weight)
  }
}

/// A plugin's data-only contribution to the host's bottom ribbon.
public struct PluginStatusBarItem: Identifiable, Sendable, Hashable {
  public let id: String
  public let label: String
  public let segments: [PluginStatusSegment]

  public init(id: String, label: String, segments: [PluginStatusSegment]) {
    self.id = id
    self.label = label
    self.segments = segments
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

/// Stable command metadata, available before a connection or workspace exists.
public struct PluginCommandDescriptor: Identifiable, Sendable {
  public let id: String
  public let title: String
  public init(id: String, title: String) {
    self.id = id
    self.title = title
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
  /// A lease on whatever can run a second command where the current tab's
  /// shell is running: another channel over SSH, another process on this
  /// machine. Optional because a tab that is still connecting has neither yet,
  /// and because a plugin that needs none should not be kept waiting for one.
  public let connection: RemoteConnection?
  public let hostLabel: String
  /// The shell behind this tab, suitable for the tmux picker's shell row.
  public let shellLabel: String
  public let hostID: UUID
  public let openWorkspace: (any PluginWorkspace) -> Void
  /// Reauthentication belongs to the host, never the plugin. No credentials cross this API.
  public let reconnect: () async throws -> RemoteConnection
  public init(
    connection: RemoteConnection?, hostLabel: String, hostID: UUID,
    shellLabel: String = "Shell",
    openWorkspace: @escaping (any PluginWorkspace) -> Void,
    reconnect: @escaping () async throws -> RemoteConnection
  ) {
    self.connection = connection
    self.hostLabel = hostLabel
    self.shellLabel = shellLabel
    self.hostID = hostID
    self.openWorkspace = openWorkspace
    self.reconnect = reconnect
  }
}

@MainActor
public protocol TetherPlugin: AnyObject {
  var metadata: PluginMetadata { get }
  var commandDescriptors: [PluginCommandDescriptor] { get }
  /// A data-only lamp shown beside the host selector, when the plugin has live status.
  var statusBarItem: PluginStatusBarItem? { get }
  /// The lamp itself, when the plugin draws it. Otherwise the host paints `statusBarItem`.
  func statusBarLabel() -> AnyView?
  /// Right-click on the lamp: a plugin that keeps its own settings window
  /// opens it from here.
  func statusBarSettings() -> (() -> Void)?
  /// Status-bar-only plugins do not add a workspace command or tab.
  var isStatusBarOnly: Bool { get }
  /// A lightweight workspace presented when the status ribbon is clicked.
  func statusBarWorkspace() -> (any PluginWorkspace)?
  /// Whether this plugin needs the tab's connection before it can be
  /// launched. tmux does — it runs commands where the shell is. A status
  /// plugin reporting on something of this device's own needs nothing from
  /// the tab at all.
  ///
  /// Named for the remote case it was written for; it is the connection that
  /// is needed, and a local session leases one too.
  var needsRemoteConnection: Bool { get }
  func activate()
  func deactivate()
  func launch(in context: PluginContext)
  func settings() -> AnyView
}
extension TetherPlugin {
  public var commandDescriptors: [PluginCommandDescriptor] { [] }
  public var statusBarItem: PluginStatusBarItem? { nil }
  public func statusBarLabel() -> AnyView? { nil }
  public func statusBarSettings() -> (() -> Void)? { nil }
  public var isStatusBarOnly: Bool { false }
  public func statusBarWorkspace() -> (any PluginWorkspace)? { nil }
  public var needsRemoteConnection: Bool { true }
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
