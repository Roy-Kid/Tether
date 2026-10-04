import Foundation

/// What a page is allowed to call. The transport pins the session before delivery.
@MainActor
public protocol PluginBridge: AnyObject {
  func deliver(_ message: String, from session: UUID) async -> String
}

/// A disposable place a plugin page runs. WebKit is one adapter.
@MainActor
public protocol PluginRuntime: AnyObject {
  func activate(session: UUID, root: URL, entrypoint: URL, bridge: any PluginBridge) async throws
  func unload(session: UUID)
}
