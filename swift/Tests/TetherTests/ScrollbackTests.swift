import Foundation
import Testing

@testable import Tether

/// Scrollback, through the Swift surface, with no view in the way.
///
/// The engine's scrollback is covered by the Rust tests. What this answers is
/// narrower and was genuinely in doubt: whether asking for it from Swift
/// reaches the engine at all. A frontend that scrolls and sees nothing cannot
/// tell a boundary that dropped the call from an event that never arrived.
@Suite("Scrollback across the boundary")
struct ScrollbackTests {
  struct Server {
    let destination: Destination
    let key: String
  }

  /// Trusts whatever the test server presents. Safe only because the endpoint
  /// comes from this test's own environment.
  struct TrustTestServer: HostTrust {
    func trusts(_ host: HostIdentity) async -> Bool { true }
  }

  static func server(rows: UInt16) -> Server? {
    let environment = ProcessInfo.processInfo.environment
    guard let host = environment["TETHER_TEST_SSH_HOST"],
      let port = environment["TETHER_TEST_SSH_PORT"].flatMap(UInt16.init),
      let user = environment["TETHER_TEST_SSH_USER"],
      let keyPath = environment["TETHER_TEST_SSH_KEY"],
      let key = try? String(contentsOfFile: keyPath, encoding: .utf8)
    else { return nil }

    return Server(
      destination: Destination(host: host, port: port, user: user, columns: 80, rows: rows),
      key: key)
  }

  /// Waits for the screen to satisfy `predicate`, or gives up.
  static func settle(
    _ session: TerminalSession, _ what: String, _ predicate: (ScreenFrame) -> Bool
  ) async throws -> ScreenFrame {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let frame = session.frame()
      if predicate(frame) { return frame }
      guard await session.awaitChange() else { break }
    }
    throw TetherError.timedOut(millis: 10_000)
  }

  static func text(_ frame: ScreenFrame) -> String {
    frame.lines.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
  }

  @Test("output that scrolled away is reachable from Swift")
  func scrollback() async throws {
    guard let server = Self.server(rows: 10) else {
      print("skipped: TETHER_TEST_SSH_* not set")
      return
    }

    let session = try await TerminalSession.connect(
      to: server.destination,
      trusting: TrustTestServer(),
      offering: [.privateKey(pem: server.key)])

    _ = try await Self.settle(session, "a prompt") { frame in
      Self.text(frame).contains { !$0.isWhitespace }
    }

    try session.send(.paste("for i in $(seq 1 40); do echo marker-$i; done\n"))

    let live = try await Self.settle(session, "the last line") { frame in
      Self.text(frame).contains("marker-40")
    }

    #expect(live.viewportOffset == 0, "the live screen")
    #expect(live.historyLines > 0, "with history behind it")
    #expect(!Self.text(live).contains("marker-1\n"), "the first line has gone past")

    // The call under test.
    session.scroll(.oldest)

    let history = session.frame()
    #expect(history.viewportOffset > 0, "the viewport left the live screen")
    #expect(history.viewportOffset == history.historyLines, "and went to the oldest line")
    #expect(Self.text(history) != Self.text(live), "showing something else")

    // Typing returns to the present, the way every terminal does.
    try session.send(.key(.enter))
    #expect(session.frame().viewportOffset == 0, "typing came back to the live screen")

    session.close()
  }
}
