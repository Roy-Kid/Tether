import Foundation
import Testing
import Tether

@testable import TetherApp

@Suite("Terminal process detection")
struct ShellActivityTests {
  private func activity(_ rows: String, terminal: String = "/dev/pts/5") -> ShellActivity {
    ShellActivity.parse("banner\nTETHER-PROCESSES\n\(rows)\nTETHER-PROCESSES-END\n", terminal: terminal)
  }

  @Test("a waiting login shell is idle on Linux and macOS")
  func idle() {
    #expect(activity("100 1 pts/5 Ss /bin/bash") == .idle)
    #expect(activity("100 1 ttys003 S+ -zsh", terminal: "/dev/ttys003") == .idle)
    #expect(activity("100 1 pts/5 Ss fish\n200 1 pts/8 S sleep") == .idle)
  }

  @Test("foreground, background and stopped jobs all need confirmation", arguments: ["S+", "S", "T"])
  func jobs(state: String) {
    #expect(activity("100 1 pts/5 Ss bash\n101 100 pts/5 \(state) /usr/bin/sleep") == .running(["sleep"]))
  }

  @Test("nested shells and descendants without a tty still belong to this tab")
  func descendants() {
    #expect(activity("100 1 pts/5 Ss zsh\n101 100 pts/5 S bash") == .running(["bash"]))
    #expect(activity("100 1 pts/5 Ss bash\n101 100 ? S worker\n102 101 ? S sleep") == .running(["sleep", "worker"]))
  }

  @Test("exec replacing the shell and a busy shell are not mistaken for idle")
  func replacedShell() {
    #expect(activity("100 1 pts/5 Ss /usr/bin/vim") == .running(["vim"]))
    #expect(activity("100 1 pts/5 Rs bash") == .running(["bash"]))
  }

  @Test("zombies are finished, and repeated names are listed once")
  func finishedAndDuplicate() {
    #expect(activity("100 1 pts/5 Ss bash\n101 100 pts/5 Z sleep") == .idle)
    #expect(activity("100 1 pts/5 Ss bash\n101 100 pts/5 S sleep\n102 100 pts/5 S sleep") == .running(["sleep"]))
  }

  @Test("failed, ambiguous and incomplete listings cannot prove the tab is idle")
  func unknown() {
    #expect(ShellActivity.parse("100 1 pts/5 S bash", terminal: "/dev/pts/5") == .unknown)
    #expect(activity("") == .unknown)
    #expect(activity("100 1 pts/8 Ss bash") == .unknown)
    #expect(activity("100 1 pts/5 Ss bash\n101 1 pts/5 S zsh") == .unknown)
    #expect(activity("100 1 pts/5 Ss bash\ntruncated") == .unknown)
  }

  @Test("a real local PTY distinguishes an idle prompt from foreground and background jobs",
    .enabled(if: TerminalSession.isLocalAvailable))
  func localPTY() async throws {
    let session = try await TerminalSession.local()
    defer { session.close() }
    let connection = try #require(session.connection)
    let tty = try #require(session.terminalName)

    func waitFor(_ expected: ShellActivity, phase: String) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      var result: ShellActivity = .unknown
      repeat {
        result = await ShellActivity.check(
          on: connection, terminal: tty, columns: 80, rows: 24, matchSize: false)
        if result == expected { return }
        try await Task.sleep(for: .milliseconds(50))
      } while ContinuousClock.now < deadline
      try #require(result == expected, "\(phase): \(result)")
    }

    try await waitFor(.idle, phase: "initial prompt")
    // A process can appear in ps before the shell gives its group the tty.
    // Wait for output from that foreground group before sending SIGINT.
    let ready = "TETHER-FOREGROUND-READY"
    try session.send(.key(.text("sh -c 'printf \"%s\\n\" \(ready); exec sleep 30'")))
    try session.send(.key(.enter))
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    func foregroundReady() -> Bool {
      session.frame().lines.contains { $0.runs.map(\.text).joined().trimmingCharacters(in: .whitespaces) == ready }
    }
    while !foregroundReady(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    try #require(foregroundReady(), "foreground job did not acquire the terminal")
    try await waitFor(.running(["sleep"]), phase: "foreground job")
    try session.send(.key(.text("c"), KeyModifiers(control: true)))
    try await waitFor(.idle, phase: "interrupted foreground job")
    try session.send(.key(.text("sleep 30 &")))
    try session.send(.key(.enter))
    try await waitFor(.running(["sleep"]), phase: "background job")
    // Seeing the child in ps does not mean the interactive prompt is ready
    // to accept another line. Clean up through the independent connection,
    // restricted to the sleep process on this test's own terminal.
    let listing = try await connection.execute(ShellActivity.listCommand)
    try #require(listing.status == 0)
    let text = try #require(String(data: listing.stdout, encoding: .utf8))
    let pids = text.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
      let fields = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
      guard fields.count == 5, ShellTTY.device(String(fields[2])) == tty else { return nil }
      // ps pads its columns; match the production parser's normalization.
      let command = fields[4].trimmingCharacters(in: .whitespaces)
      guard command.split(separator: "/").last == "sleep" else { return nil }
      return Int(fields[0])
    }
    try #require(pids.count == 1)
    let pid = try #require(pids.first)
    let killed = try await connection.execute("kill -TERM \(pid)")
    try #require(killed.status == 0)
    try await waitFor(.idle, phase: "reaped background job")
  }
}
