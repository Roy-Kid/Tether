import Foundation
import Testing
import Tether

/// Whether this machine has the program the test is about.
///
/// A skip rather than a failure: tmux is not a dependency of Tether, and a
/// build machine without one has nothing wrong with it.
private let tmuxIsInstalled: Bool = {
  let which = Process()
  which.executableURL = URL(fileURLWithPath: "/bin/sh")
  which.arguments = ["-lc", "command -v tmux"]
  which.standardOutput = FileHandle.nullDevice
  which.standardError = FileHandle.nullDevice
  try? which.run()
  which.waitUntilExit()
  return which.terminationStatus == 0
}()

/// The same journey as the SSH round trip, over a shell on this machine.
///
/// It is the claim in §8 made expensive to break. A tmux workspace is built
/// on "run a second command where this session's shell is", and the whole
/// point of that being one idea rather than two is that this test is the
/// other one with the handshake deleted — no host, no key, no fingerprint,
/// and otherwise the same calls in the same order.
@Test(
  "Swift → a local shell → tmux preserves independent channel lifetimes",
  .enabled(if: tmuxIsInstalled))
func localTmuxRoundTrip() async throws {
  let shell = try await TerminalSession.local()
  let connection = try #require(
    shell.connection, "a local session leases a connection like any other")
  let session = try await connection.createTmux(name: "tether-local-test-\(UUID().uuidString)")

  do {
    let listed = try await connection.tmuxSessions()
    #expect(listed.contains { $0.id == session.id })
    let found = try #require(listed.first { $0.id == session.id })
    #expect(!found.windows.isEmpty, "listing must include windows without attaching")

    let workspace = try await connection.attachTmux(sessionID: session.id)
    defer { workspace.detach() }
    let initial = try await settle(workspace) { $0.panes.count == 1 }
    let first = try #require(initial.panes.first)
    let directory = try await connection.tmuxPaneDirectory(id: first.id)
    #expect(directory.hasPrefix("/"), "tmux knows where the pane is: \(directory)")

    try await workspace.perform(.split(id: first.id, horizontal: true))
    _ = try await settle(workspace) { $0.panes.count == 2 }

    // The shell the workspace was reached through goes away, and the
    // workspace does not. Nothing about the tmux session was living on the
    // terminal session's stream — which is the lifetime claim, and the one
    // thing a shared transport would quietly break.
    shell.close()
    try workspace.send(pane: first.id, input: .paste("printf TETHER_LOCAL_OK"))
    try workspace.send(pane: first.id, input: .key(.enter))
    _ = try await settle(workspace) { snapshot in
      snapshot.panes.contains { pane in
        pane.frame.lines.contains { row in
          row.runs.map(\.text).joined().contains("TETHER_LOCAL_OK")
        }
      }
    }

    workspace.detach()
    let surviving = try await connection.tmuxSessions()
    #expect(surviving.contains { $0.id == session.id }, "detaching must not end the session")

    let restored = try await connection.attachTmux(sessionID: session.id)
    defer { restored.detach() }
    _ = try await settle(restored) { $0.panes.count == 2 }

    try await connection.endTmux(sessionID: session.id)
  } catch {
    try? await connection.endTmux(sessionID: session.id)
    shell.close()
    throw error
  }
}

/// The picker closes windows of sessions nobody here is attached to, so
/// ending one must not need a control client.
@Test("A window ends without attaching to its session", .enabled(if: tmuxIsInstalled))
func localTmuxWindowEndsDetached() async throws {
  let shell = try await TerminalSession.local()
  defer { shell.close() }
  let connection = try #require(shell.connection)
  let session = try await connection.createTmux(name: "tether-window-test-\(UUID().uuidString)")

  do {
    let workspace = try await connection.attachTmux(sessionID: session.id)
    _ = try await settle(workspace) { $0.windows.count == 1 }
    try await workspace.perform(.newWindow)
    _ = try await settle(workspace) { $0.windows.count == 2 }
    workspace.detach()

    let before = try #require(try await connection.tmuxSessions().first { $0.id == session.id })
    #expect(before.windows.count == 2)
    let doomed = try #require(before.windows.first)

    try await connection.endTmuxWindow(id: doomed.id)

    let after = try #require(try await connection.tmuxSessions().first { $0.id == session.id })
    #expect(after.windows.map(\.id) == before.windows.dropFirst().map(\.id))
    try await connection.endTmux(sessionID: session.id)
  } catch {
    try? await connection.endTmux(sessionID: session.id)
    throw error
  }
}

private func settle(_ workspace: TmuxWorkspace, condition: (TmuxSnapshot) -> Bool) async throws
  -> TmuxSnapshot
{
  for _ in 0..<500 {
    let snapshot = workspace.snapshot()
    if let ended = snapshot.ended {
      throw NSError(domain: "LocalTmuxTest", code: 1, userInfo: [NSLocalizedDescriptionKey: ended])
    }
    if condition(snapshot) { return snapshot }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw NSError(
    domain: "LocalTmuxTest", code: 2,
    userInfo: [NSLocalizedDescriptionKey: "Workspace update timed out"])
}
