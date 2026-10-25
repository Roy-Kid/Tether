#if os(iOS)
  import ActivityKit
  import Foundation

  /// One plugin's living status. Compiled into the app and into the Live
  /// Activity extension, so both sides name the same fields.
  public struct PluginLiveAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
      public var name: String
      public var detail: String
      public var tint: UInt32

      public init(name: String, detail: String, tint: UInt32) {
        self.name = name
        self.detail = detail
        self.tint = tint
      }
    }

    public var pluginID: String

    public init(pluginID: String) {
      self.pluginID = pluginID
    }
  }
#endif
