import Foundation
import Testing

@testable import Tether

/// A session on a shell running on this machine.
///
/// These need no server, which is the point of having them: the SSH suites
/// are skipped unless one is configured, so without this file the boundary
/// is usually crossed by nothing but a timeout probe.
///
/// What is being checked is sameness. Every assertion here goes through the
/// API `TerminalSession.connect` returns, so if a local session needed
/// special handling anywhere, this file could not have been written without
/// saying so.
@Suite("A local session", .enabled(if: TerminalSession.isLocalAvailable))
struct LocalSessionTests {
  @Test("a name with no ControlPath is not a master")
  func noControlPathIsNotAMaster() async {
    #expect(await TerminalSession.sshMasterIsRunning("tether-no-such-mux-host") == false)
  }

  /// Waits until `predicate` holds, or gives up.
  ///
  /// The final frame is announced before the ending is, so a shell that
  /// writes and exits in the same breath has to be checked once more after
  /// the session stops rather than being declared a failure.
  private func settle(
    _ session: TerminalSession, _ what: String, _ predicate: (String) -> Bool
  ) async -> String {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while true {
      let screen = Self.text(session.frame())
      if predicate(screen) { return screen }
      if ContinuousClock.now >= deadline {
        Issue.record("timed out waiting for \(what); the screen held:\n\(screen)")
        return screen
      }
      if await session.awaitChange() == false {
        let last = Self.text(session.frame())
        if !predicate(last) {
          Issue.record("the session ended while waiting for \(what); the screen held:\n\(last)")
        }
        return last
      }
    }
  }

  private static func text(_ frame: ScreenFrame) -> String {
    frame.lines.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
  }

  @Test("opens without a host, a user or a credential")
  func opensWithNothing() async throws {
    // The absence is the assertion. A local session needs none of the
    // ceremony a remote one does, and a shape that demanded a placeholder
    // host would be admitting the two are different kinds of thing.
    let session = try await TerminalSession.local()
    defer { session.close() }
    #expect(session.ending() == nil)
  }

  @Test("history crosses the Swift boundary and reopens as displayed content")
  func persistentHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "tether-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = try SessionHistory(directory: directory, lineLimit: nil)
    let first = try await TerminalSession.local(LocalShell(columns: 80, rows: 24, history: history))
    try first.send(.paste("printf '\\033[31mffi''-history\\033[0m\\n'\n"))
    _ = await settle(first, "the archived marker") { $0.contains("ffi-history") }
    first.close()
    #expect(history.error == nil)
    let reopened = try SessionHistory(directory: directory, lineLimit: nil, restoring: true)
    let second = try await TerminalSession.local(LocalShell(columns: 80, rows: 24, history: reopened))
    defer { second.close() }
    // Restoring should show recent content immediately, before any scrolling.
    #expect(Self.text(second.frame()).contains("ffi-history"))
    #expect(second.historyError == nil)
  }

  @Test("draws what the shell writes")
  func drawsOutput() async throws {
    let session = try await TerminalSession.local(
      LocalShell(columns: 80, rows: 24))
    defer { session.close() }

    try session.send(.paste("printf 'from''-swift\\n'\n"))
    let screen = await settle(session, "the shell's reply") { $0.contains("from-swift") }
    #expect(screen.contains("from-swift"))
  }

  @Test("names what its output points at, and where its shell is")
  func linksAndWorkingDirectory() async throws {
    let session = try await TerminalSession.local(LocalShell(columns: 80, rows: 24))
    defer { session.close() }

    try session.send(.paste("printf '\\033]7;file://here/tmp/runs\\007wrote out/pl''ot.png\\n'\n"))
    _ = await settle(session, "the path") { $0.contains("wrote out/plot.png") }

    #expect(session.workingDirectory == "/tmp/runs")
    let frame = session.frame()
    let row = try #require(
      frame.lines.firstIndex { line in line.runs.map(\.text).joined().hasPrefix("wrote out/") })
    let link = try #require(session.link(atRow: UInt16(row), column: 8))
    #expect(link.text == "out/plot.png")
    #expect(link.kind == .path(path: "out/plot.png", line: nil, column: nil))
    #expect(link.spans == [LinkSpan(row: UInt16(row), start: 6, end: 18)])
  }

  @Test("carries typing through to the shell")
  func carriesTyping() async throws {
    let session = try await TerminalSession.local()
    defer { session.close() }

    for character in "printf 'ty''ped\\n'" {
      try session.send(.key(.text(String(character))))
    }
    try session.send(.key(.enter))

    let screen = await settle(session, "the shell's reply") { $0.contains("typed") }
    #expect(screen.contains("typed"))
  }

  @Test("tells the shell how big the screen is")
  func tellsTheShellItsSize() async throws {
    let session = try await TerminalSession.local(LocalShell(columns: 120, rows: 40))
    defer { session.close() }

    try session.send(.paste("stty size; printf 'DO''NE\\n'\n"))
    let screen = await settle(session, "stty's answer") { $0.contains("DONE") }
    #expect(screen.contains("40 120"))
  }

  @Test("a second shell opens on the leased connection")
  func secondShellOnTheLease() async throws {
    let first = try await TerminalSession.local()
    defer { first.close() }
    let connection = try #require(first.connection)
    let second = try await connection.openShell()
    defer { second.close() }
    #expect(second.ending() == nil)

    try first.send(.paste("printf 'one''\\n'\n"))
    try second.send(.paste("printf 'two''\\n'\n"))
    let firstScreen = await settle(first, "the first shell's reply") { $0.contains("one") }
    let secondScreen = await settle(second, "the second shell's reply") { $0.contains("two") }
    #expect(firstScreen.contains("one"))
    #expect(secondScreen.contains("two"))
  }

  @Test("the far side can be told what this application draws with")
  func carriesAPalette() async throws {
    let session = try await TerminalSession.local()
    defer { session.close() }

    let grey = TerminalColor(red: 0x80, green: 0x80, blue: 0x80)
    try session.setPalette(
      TerminalPalette(
        foreground: TerminalColor(red: 0x1f, green: 0x21, blue: 0x28),
        background: TerminalColor(red: 0xfb, green: 0xfb, blue: 0xfd),
        cursor: TerminalColor(red: 0x00, green: 0x7a, blue: 0xff),
        ansi: Array(repeating: grey, count: 16)))

    // Saying nothing is a thing an application is allowed to do, and it is
    // what it did before there was a palette to say.
    try session.setPalette(nil)
  }

  @Test("a palette that is not sixteen colours is refused, not padded")
  func refusesAShortPalette() async throws {
    let session = try await TerminalSession.local()
    defer { session.close() }

    let grey = TerminalColor(red: 0x80, green: 0x80, blue: 0x80)
    #expect(throws: (any Error).self) {
      try session.setPalette(
        TerminalPalette(
          foreground: grey, background: grey, cursor: grey,
          ansi: Array(repeating: grey, count: 8)))
    }
  }

  @Test("leases a connection of its own")
  func leasesAConnection() async throws {
    // Not a special case a frontend has to remember: it asks, and both kinds
    // of session answer the same way. Nothing was authenticated here and
    // nothing is held open — but a second command can be run on this machine
    // just as it can on the far side of a network, and a feature built on
    // that is a feature that did not have to be written twice.
    let session = try await TerminalSession.local()
    defer { session.close() }
    #expect(session.connection != nil)
  }

  @Test("starts where it was told to")
  func startsInADirectory() async throws {
    let session = try await TerminalSession.local(LocalShell(directory: "/"))
    defer { session.close() }

    try session.send(.paste("pwd; printf 'HE''RE\\n'\n"))
    let screen = await settle(session, "pwd's answer") { $0.contains("HERE") }
    #expect(screen.contains("/"))
  }
}
