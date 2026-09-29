import Foundation
import TetherFFIBindings

public typealias TmuxSessionInfo = TetherFFIBindings.TmuxSessionInfo
public typealias TmuxListedWindow = TetherFFIBindings.TmuxListedWindow
public typealias TmuxWindowInfo = TetherFFIBindings.TmuxWindowInfo
public typealias TmuxPaneFrame = TetherFFIBindings.TmuxPaneFrame
public typealias TmuxSnapshot = TetherFFIBindings.TmuxSnapshot
public typealias TmuxAction = TetherFFIBindings.TmuxAction

public struct CommandOutput: Sendable {
  public let status: Int32?
  public let stdout: Data
  public let stderr: Data
}

/// A lease on an authenticated connection, independent of any shell channel.
public final class RemoteConnection: Sendable {
  let inner: TetherFFIBindings.RemoteConnection
  init(_ inner: TetherFFIBindings.RemoteConnection) { self.inner = inner }

  /// Opens an interactive shell on this lease.
  ///
  /// No handshake: the connection is already authenticated. A second terminal
  /// is another channel (or another process, on this machine), which is why
  /// a person who is already connected is not asked for a password again.
  public func openShell(
    term: String = "xterm-256color",
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    scrollbackLines: UInt32 = defaultScrollbackLines
  ) async throws -> TerminalSession {
    let session = try await cancellable { token in
      try await self.inner.openShell(
        term: term,
        columns: columns,
        rows: rows,
        scrollbackLines: scrollbackLines,
        cancellation: token)
    }
    return TerminalSession(session)
  }

  /// Runs a bounded command on this authenticated lease, independently of a terminal.
  public func execute(_ command: String) async throws -> CommandOutput {
    let result = try await cancellable { try await self.inner.execute(command: command, cancellation: $0) }
    return CommandOutput(status: result.status, stdout: result.stdout, stderr: result.stderr)
  }

  public func tmuxSessions() async throws -> [TmuxSessionInfo] {
    try await cancellable { try await self.inner.tmuxSessions(cancellation: $0) }
  }
  public func tmuxSession(forClientTTY tty: String) async throws -> String? {
    try await Tether.mapped { try await self.inner.tmuxSessionForClient(tty: tty) }
  }
  public func createTmux(name: String, directory: String? = nil) async throws -> TmuxSessionInfo {
    try await cancellable {
      try await self.inner.createTmux(name: name, directory: directory, cancellation: $0)
    }
  }
  public func attachTmux(sessionID: String) async throws -> TmuxWorkspace {
    let workspace = try await cancellable {
      try await self.inner.attachTmux(sessionId: sessionID, cancellation: $0)
    }
    return TmuxWorkspace(workspace)
  }
  /// Where tmux says a pane's program is (`#{pane_current_path}`): known
  /// even when the pane's shell reports nothing.
  public func tmuxPaneDirectory(id: UInt32) async throws -> String {
    try await Tether.mapped { try await self.inner.tmuxPaneDirectory(paneId: id) }
  }
  public func renameTmux(sessionID: String, name: String) async throws {
    try await Tether.mapped { try await self.inner.renameTmux(sessionId: sessionID, name: name) }
  }
  public func endTmux(sessionID: String) async throws {
    try await Tether.mapped { try await self.inner.endTmux(sessionId: sessionID) }
  }
  /// Ends one window of any session, attached or not.
  public func endTmuxWindow(id: UInt32) async throws {
    try await Tether.mapped { try await self.inner.endTmuxWindow(windowId: id) }
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
  public func scroll(pane: UInt32, lines: Int32) async throws {
    try await Tether.mapped { try await inner.scroll(pane: pane, lines: lines) }
  }
  public func perform(_ action: TmuxAction) async throws {
    try await Tether.mapped { try await self.inner.perform(action: action) }
  }
  public func detach() { inner.detach() }
  /// What the text at a cell of a pane names, as `TerminalSession.link`.
  public func link(pane: UInt32, row: UInt16, column: UInt16) -> TerminalLink? {
    inner.linkAt(pane: pane, row: row, column: column)
  }
  /// The directory a pane's shell last reported, if it reports one.
  public func workingDirectory(pane: UInt32) -> String? {
    inner.workingDirectory(pane: pane)
  }
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
