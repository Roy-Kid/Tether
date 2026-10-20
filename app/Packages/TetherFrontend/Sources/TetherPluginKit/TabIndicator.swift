import Foundation

/// A terminal on its actual machine, not a display title or saved-host alias.
/// The host obtains these from the shell's lease; producers report the same facts.
public struct PluginTerminalIdentity: Codable, Hashable, Sendable {
  public let host: String
  public let terminal: String

  public init(host: String, terminal: String) {
    self.host = host.lowercased()
    self.terminal = terminal
  }
}

/// One data-only circle before a tab's name. The host owns its geometry.
public struct PluginTabIndicator: Codable, Equatable, Sendable {
  public let target: PluginTerminalIdentity
  public let color: UInt32
  public let label: String

  public init(target: PluginTerminalIdentity, color: UInt32, label: String) {
    self.target = target
    self.color = color
    self.label = label
  }
}

/// The SF Symbol a plugin wants in front of a terminal tab's name.
///
/// The host draws it. A plugin names a symbol; it does not draw the tab.
public struct PluginTabSymbol: Equatable, Sendable {
  public let target: PluginTerminalIdentity
  public let symbol: String

  public init(target: PluginTerminalIdentity, symbol: String) {
    self.target = target
    self.symbol = symbol
  }
}
