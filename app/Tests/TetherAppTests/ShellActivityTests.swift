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

    func waitFor(_ expected: ShellActivity) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      var result: ShellActivity = .unknown
      repeat {
        result = await ShellActivity.check(
          on: connection, terminal: tty, columns: 80, rows: 24, matchSize: false)
        if result == expected { return }
        try await Task.sleep(for: .milliseconds(50))
      } while ContinuousClock.now < deadline
      #expect(result == expected)
    }

    try await waitFor(.idle)
    try session.send(.key(.text("sleep 30")))
    try session.send(.key(.enter))
    try await waitFor(.running(["sleep"]))
    try session.send(.key(.text("c"), KeyModifiers(control: true)))
    try await waitFor(.idle)
    try session.send(.key(.text("sleep 30 &")))
    try session.send(.key(.enter))
    try await waitFor(.running(["sleep"]))
    try session.send(.key(.text("kill $!; wait")))
    try session.send(.key(.enter))
    try await waitFor(.idle)
  }
}

@MainActor
@Suite("Checking ahead of a close")
struct CloseCheckTests {
  /// A check that counts how often it ran and answers what it is told.
  final class Probe {
    var answer: ShellActivity = .idle
    var runs = 0
  }

  private func settle(_ check: CloseCheck, until done: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !done() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
  }

  @Test("an idle answer taken after the last activity closes without another check")
  func idleIsReused() async throws {
    let probe = Probe()
    let check = CloseCheck(quiet: .milliseconds(20)) { probe.runs += 1; return probe.answer }
    check.noteActivity()
    try await settle(check) { probe.runs == 1 }
    #expect(probe.runs == 1, "checked ahead once the terminal was quiet")
    #expect(await check.activity() == .idle)
    #expect(probe.runs == 1, "the close used the answer it already had")
  }

  @Test("activity after the answer, or an answer other than idle, is checked again")
  func staleOrBusyIsCheckedAgain() async throws {
    let probe = Probe()
    let check = CloseCheck(quiet: .seconds(60)) { probe.runs += 1; return probe.answer }
    #expect(await check.activity() == .idle)
    #expect(probe.runs == 1)
    check.noteActivity()
    probe.answer = .running(["sleep"])
    #expect(await check.activity() == .running(["sleep"]), "typing since the answer can start work")
    #expect(probe.runs == 2)
    probe.answer = .idle
    #expect(await check.activity() == .idle, "work can finish silently, so running is never kept")
    #expect(probe.runs == 3)
    probe.answer = .unknown
    check.reset()
    #expect(await check.activity() == .unknown)
    #expect(await check.activity() == .unknown)
    #expect(probe.runs == 5, "an unknown answer is never kept")
  }

  @Test("a close during a check ahead waits for that check rather than starting another")
  func inFlightIsShared() async throws {
    let probe = Probe()
    var release: CheckedContinuation<Void, Never>?
    let check = CloseCheck(quiet: .milliseconds(10)) {
      probe.runs += 1
      await withCheckedContinuation { release = $0 }
      return .idle
    }
    check.noteActivity()
    try await settle(check) { release != nil }
    async let closing = check.activity()
    try await Task.sleep(for: .milliseconds(20))
    release?.resume()
    #expect(await closing == .idle)
    #expect(probe.runs == 1)
  }

  @Test("an idle local tab closes without waiting for a process listing",
    .enabled(if: TerminalSession.isLocalAvailable))
  func localTabClosesFromTheAnswerAhead() async throws {
    let session = try await TerminalSession.local()
    defer { session.close() }
    let connection = try #require(session.connection)
    let tty = try #require(session.terminalName)
    let probe = Probe()
    let check = CloseCheck(quiet: .milliseconds(300)) {
      let answer = await ShellActivity.check(on: connection, terminal: tty, columns: 80, rows: 24, matchSize: false)
      probe.runs += 1
      return answer
    }
    // The shell starts, prints its prompt, and goes quiet.
    var listed: ShellActivity = .unknown
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while listed != .idle && ContinuousClock.now < deadline {
      listed = await ShellActivity.check(on: connection, terminal: tty, columns: 80, rows: 24, matchSize: false)
    }
    #expect(listed == .idle)
    check.noteActivity()
    try await settle(check) { probe.runs == 1 }

    #expect(await check.activity() == .idle)
    #expect(probe.runs == 1, "closing listed the processes again")

    try session.send(.key(.text("sleep 30")))
    try session.send(.key(.enter))
    check.noteActivity()
    var running: ShellActivity = .idle
    let busy = ContinuousClock.now.advanced(by: .seconds(10))
    repeat {
      running = await check.activity()
      if running == .running(["sleep"]) { break }
      check.noteActivity()
      try await Task.sleep(for: .milliseconds(50))
    } while ContinuousClock.now < busy
    #expect(running == .running(["sleep"]), "work started after an idle answer is still found")
  }
}
