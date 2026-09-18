import Foundation
import TetherFFIBindings

public typealias TmuxSessionInfo = TetherFFIBindings.TmuxSessionInfo
public typealias TmuxWindowInfo = TetherFFIBindings.TmuxWindowInfo
public typealias TmuxPaneFrame = TetherFFIBindings.TmuxPaneFrame
public typealias TmuxSnapshot = TetherFFIBindings.TmuxSnapshot
public typealias TmuxAction = TetherFFIBindings.TmuxAction

/// A lease on an authenticated connection, independent of any shell channel.
public final class RemoteConnection: Sendable {
  private let inner: TetherFFIBindings.RemoteConnection
  init(_ inner: TetherFFIBindings.RemoteConnection) { self.inner = inner }

  public func tmuxSessions() async throws -> [TmuxSessionInfo] {
    try await cancellable { try await self.inner.tmuxSessions(cancellation: $0) }
  }
  public func createTmux(name: String) async throws -> TmuxSessionInfo {
    try await cancellable { try await self.inner.createTmux(name: name, cancellation: $0) }
  }
  public func attachTmux(sessionID: String) async throws -> TmuxWorkspace {
    let workspace = try await cancellable {
      try await self.inner.attachTmux(sessionId: sessionID, cancellation: $0)
    }
    return TmuxWorkspace(workspace)
  }
  public func renameTmux(sessionID: String, name: String) async throws {
    try await Tether.mapped { try await self.inner.renameTmux(sessionId: sessionID, name: name) }
  }
  public func endTmux(sessionID: String) async throws {
    try await Tether.mapped { try await self.inner.endTmux(sessionId: sessionID) }
  }
}

/// Pane frames and layout share one snapshot so geometry and drawing stay consistent.
public final class TmuxWorkspace: Sendable {
  private let inner: TetherFFIBindings.TmuxWorkspace
  init(_ inner: TetherFFIBindings.TmuxWorkspace) { self.inner = inner }
  public func snapshot() -> TmuxSnapshot { inner.snapshot() }
  public func awaitChange() async -> Bool { await inner.awaitChange() }
  public func send(pane: UInt32, input: TerminalInput) throws {
    try Tether.mappedSync { try inner.send(pane: pane, input: bridged(input)) }
  }
  public func perform(_ action: TmuxAction) async throws {
    try await Tether.mapped { try await self.inner.perform(action: action) }
  }
  public func detach() { inner.detach() }
}

private func cancellable<T: Sendable>(
  _ body: @escaping @Sendable (TetherFFIBindings.CancellationToken) async throws -> T
) async throws -> T {
  let token = TetherFFIBindings.CancellationToken()
  return try await withTaskCancellationHandler {
    try Task.checkCancellation()
    let result = try await Tether.mapped { try await body(token) }
    try Task.checkCancellation()
    return result
  } onCancel: {
    token.cancel()
  }
}
