import Foundation
import Testing
import Tether

private struct FixtureTrust: HostTrust {
  let fingerprint: String
  func trusts(_ host: HostIdentity) async -> Bool { host.fingerprint == fingerprint }
}

@Test(
  "Swift → SSH → tmux preserves independent channel lifetimes",
  .enabled(if: ProcessInfo.processInfo.environment["TETHER_TEST_SSH_FINGERPRINT"] != nil))
func nativeTmuxRoundTrip() async throws {
  let env = ProcessInfo.processInfo.environment
  let host = try #require(env["TETHER_TEST_SSH_HOST"])
  let port = try #require(env["TETHER_TEST_SSH_PORT"].flatMap(UInt16.init))
  let user = try #require(env["TETHER_TEST_SSH_USER"])
  let key = try String(contentsOfFile: #require(env["TETHER_TEST_SSH_KEY"]), encoding: .utf8)
  let fingerprint = try #require(env["TETHER_TEST_SSH_FINGERPRINT"])
  let shell = try await TerminalSession.connect(
    to: Destination(host: host, port: port, user: user),
    trusting: FixtureTrust(fingerprint: fingerprint),
    offering: [.privateKey(pem: key)])
  let connection = try #require(shell.connection)
  let session = try await connection.createTmux(name: "tether-test-\(UUID().uuidString)")
  do {
    let listed = try await connection.tmuxSessions()
    #expect(listed.contains { $0.id == session.id })
    let workspace = try await connection.attachTmux(sessionID: session.id)
    defer { workspace.detach() }
    let initial = try await waitFor(workspace) { $0.panes.count == 1 }
    let first = try #require(initial.panes.first)
    try await workspace.perform(.split(id: first.id, horizontal: true))
    _ = try await waitFor(workspace) { $0.panes.count == 2 }
    shell.close()
    try workspace.send(pane: first.id, input: .paste("printf TETHER_FFI_OK"))
    try workspace.send(pane: first.id, input: .key(.enter))
    _ = try await waitFor(workspace) { snapshot in
      snapshot.panes.contains { pane in
        pane.frame.lines.contains { row in row.runs.map(\.text).joined().contains("TETHER_FFI_OK") }
      }
    }
    workspace.detach()
    let surviving = try await connection.tmuxSessions()
    #expect(surviving.contains { $0.id == session.id })
    let restored = try await connection.attachTmux(sessionID: session.id)
    defer { restored.detach() }
    _ = try await waitFor(restored) { $0.panes.count == 2 }
    try await connection.endTmux(sessionID: session.id)
  } catch {
    try? await connection.endTmux(sessionID: session.id)
    shell.close()
    throw error
  }
}

private func waitFor(_ workspace: TmuxWorkspace, condition: (TmuxSnapshot) -> Bool) async throws
  -> TmuxSnapshot
{
  for _ in 0..<500 {
    let snapshot = workspace.snapshot()
    if let ended = snapshot.ended {
      throw NSError(domain: "TmuxTest", code: 1, userInfo: [NSLocalizedDescriptionKey: ended])
    }
    if condition(snapshot) { return snapshot }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw NSError(
    domain: "TmuxTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace update timed out"]
  )
}
