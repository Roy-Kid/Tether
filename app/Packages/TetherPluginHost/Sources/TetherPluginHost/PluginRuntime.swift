import Foundation
import TetherPluginKit

/// What a page is allowed to call. The transport pins the session before delivery.
@MainActor
public protocol PluginBridge: AnyObject {
  func deliver(_ message: String, from session: UUID) async -> String
}

/// A disposable place a plugin page runs. WebKit is one adapter.
@MainActor
public protocol PluginRuntime: AnyObject {
  func bind(_ environment: PluginEnvironment)
  func activate(session: UUID, root: URL, entrypoint: URL, bridge: any PluginBridge) async throws
  func unload(session: UUID)
  func receive(event: JSONValue, session: UUID) async
}

extension PluginRuntime {
  public func bind(_ environment: PluginEnvironment) {}
  public func receive(event: JSONValue, session: UUID) async {}
}
