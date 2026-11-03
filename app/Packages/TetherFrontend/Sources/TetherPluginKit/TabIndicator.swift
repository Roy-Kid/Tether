import Foundation

/// A terminal on its machine, named the one way the host and every plugin
/// name it.
///
/// `host` is the machine. A remote shell's is the `~/.ssh/config` Host it was
/// opened with: that stanza decides where `ssh` lands, so whatever reached the
/// machine through it — a status hub, say — names the same place. A local
/// shell's is this Mac's Bonjour name, `<LocalHostName>.local`. Never a display
/// title, and never the far side's own hostname, which a Mac changes with its
/// network. Lowercase. `terminal` is the controlling tty.
public struct PluginTerminalIdentity: Codable, Hashable, Sendable {
  public let host: String
  public let terminal: String

  public init(host: String, terminal: String) {
    self.host = host.lowercased()
    self.terminal = terminal
  }

  /// The one comparison: the same machine and the same tty, however the tty
  /// was spelled.
  public func matches(_ other: PluginTerminalIdentity) -> Bool {
    host == other.host && TerminalName.same(terminal, other.terminal)
  }
}

/// One tty, however a producer spelled it.
///
/// `ps` prints `ttys004` or `s004`. A pty name is `/dev/ttys004`. Those are
/// the same device.
public enum TerminalName {
  public static func same(_ left: String, _ right: String) -> Bool {
    canonical(left) == canonical(right)
  }

  public static func canonical(_ raw: String) -> String {
    var value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("/dev/") { value.removeFirst("/dev/".count) }
    if value.hasPrefix("s"), value.dropFirst().allSatisfy(\.isNumber) {
      value = "tty" + value
    }
    return value
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
