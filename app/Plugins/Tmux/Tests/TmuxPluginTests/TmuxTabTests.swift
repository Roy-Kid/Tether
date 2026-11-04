import Foundation
import SwiftUI
import Testing
import Tether
import TetherPluginKit
import TetherUI

@testable import TmuxPlugin

/// A tab as the host would hand it over, recording what the plugin asked
/// the host to do. No connection: nothing here reaches a tmux server.
@MainActor
private final class HostProbe {
  var focused: [UUID] = []
  var dismissed: [UUID] = []
  var renamed: [(UUID, String)] = []
  /// What a status plugin reports, by tty, as the host would look it up.
  var marks: [String: PluginTabIndicator] = [:]
  var askedMarks: [[String]] = []
  let host = UUID()
  /// The machine its shells are on, as the host names it.
  var machine = "lab"

  func context(
    _ id: UUID = UUID(), host: UUID? = nil, terminalName: @escaping () -> String? = { nil }
  ) -> TabContext {
    TabContext(
      id: id,
      plugin: PluginContext(
        connection: nil, hostLabel: "lab", hostID: host ?? self.host,
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      terminalName: terminalName,
      terminalHost: { [unowned self] in machine },
      focus: { [unowned self] in focused.append(id) },
      dismissAccessory: { [unowned self] in dismissed.append(id) },
      present: { _ in },
      dismissSheet: {},
      renameShell: { [unowned self] id, name in renamed.append((id, name)) },
      terminalIndicator: { [unowned self] ttys in
        askedMarks.append(ttys)
        return ttys.lazy.compactMap { self.marks[$0] }.first
      })
  }
}

private func info(_ id: String, _ name: String) -> TmuxSessionInfo {
  TmuxSessionInfo(id: id, name: name, attached: false, windows: [])
}

@MainActor
@Suite("tmux on a tab")
struct TmuxTabTests {

  @Test("choosing a session on another tab does not take this terminal over")
  func anotherTerminalStays() async throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let firstID = UUID()
    let first = try #require(plugin.attach(to: host.context(firstID)) as? TmuxTab)
    let second = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    first.shellSessionID = "$1"

    second.choose(info("$1", "dev"), windowID: nil)

    #expect(host.focused == [firstID], "a shell that has not entered tmux switches to the tab that has the session")
    #expect(first.shellSessionID == "$1")
    #expect(second.error == nil)
    #expect(!second.busy)
    #expect(!second.isShowing, "the terminal is never replaced")
  }

  @Test("every tmux server has a $0: another host's is not this one")
  func ownershipIsPerHost() async throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let local = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    let remote = try #require(plugin.attach(to: host.context(host: UUID())) as? TmuxTab)
    local.shellSessionID = "$0"

    remote.choose(info("$0", "main"), windowID: nil)

    #expect(host.focused.isEmpty)
    #expect(local.shellSessionID == "$0", "the local $0 is not the one chosen")
    for _ in 0..<50 where remote.busy { await Task.yield() }
    #expect(remote.error == "Not connected.")
    #expect(remote.shellSessionID == nil)
  }

  @Test("a closed tab no longer owns its session")
  func closeForgets() throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let first = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    first.shellSessionID = "$1"
    #expect(plugin.tab(owning: "$1", on: host.host) === first)
    plugin.remember([("/dev/pts/3", "$1")], on: host.host)
    // Another machine's pts/3 is not this pane.
    #expect(!plugin.claimTerminal(host: "gpu", terminal: "pts/3"))
    #expect(host.focused.isEmpty)
    #expect(plugin.claimTerminal(host: "lab", terminal: "pts/3"))
    #expect(host.focused == [first.tab.id])

    first.close()
    #expect(plugin.tab(owning: "$1", on: host.host) == nil)
  }

  @Test("a shell beside a client lists that host's sessions before its own read")
  func sessionsFollowTheHost() async throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let client = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    let shell = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    let elsewhere = try #require(plugin.attach(to: host.context(host: UUID())) as? TmuxTab)
    client.sessions = [info("$1", "dev"), info("$2", "ops")]

    #expect(shell.listedSessions.map(\.name) == ["dev", "ops"])
    #expect(elsewhere.listedSessions.isEmpty, "another host's server is not this one")

    shell.refresh()
    #expect(shell.sessions.map(\.name) == ["dev", "ops"])
    for _ in 0..<100 where shell.busy { try await Task.sleep(for: .milliseconds(5)) }
    #expect(shell.error == "Not connected.")
    #expect(!shell.sessionsLoaded)
    #expect(shell.sessions.map(\.name) == ["dev", "ops"], "a failed read keeps the host's list")
  }

  @Test("the shell's client list follows a session chosen in the terminal")
  func clientListFollowsTheShell() throws {
    let host = HostProbe()
    let tab = try #require(
      TmuxPlugin().attach(to: host.context(terminalName: { "/dev/ttys001" })) as? TmuxTab)
    defer { tab.close() }
    let now = Date()

    tab.noteClients(listed: "/dev/ttys001|$2\n/dev/ttys002|$3\n", epoch: tab.clientEpoch, now: now)
    #expect(tab.shellSessionID == "$2")
    #expect(tab.symbol == TmuxPlugin.symbol)

    tab.noteClients(listed: "ttys001|$9\n", epoch: tab.clientEpoch, now: now)
    #expect(tab.shellSessionID == "$9")

    let seen = tab.clientEpoch
    tab.holdFollowers()
    tab.noteClients(listed: "ttys001|$1\n", epoch: seen, now: now.addingTimeInterval(10))
    #expect(tab.shellSessionID == "$9", "a list taken before the switch is dropped")
    tab.noteClients(listed: "ttys001|$1\n", epoch: tab.clientEpoch, now: now)
    #expect(tab.shellSessionID == "$9", "the switch keeps its session until the server can confirm it")
    tab.noteClients(listed: "ttys001|$1\n", epoch: tab.clientEpoch, now: now.addingTimeInterval(10))
    #expect(tab.shellSessionID == "$1")

    tab.noteClients(listed: "/dev/ttys002|$3\n", epoch: tab.clientEpoch, now: now.addingTimeInterval(10))
    #expect(tab.shellSessionID == nil, "a tty missing from a finished list has detached")

    tab.noteClients(listed: "ttys001|$4\n", epoch: tab.clientEpoch, now: now.addingTimeInterval(10))
    #expect(tab.shellSessionID == "$4")
    tab.busy = true
    tab.noteClients(listed: "ttys001|$5\n", epoch: tab.clientEpoch, now: now.addingTimeInterval(10))
    #expect(tab.shellSessionID == "$4", "a switch in progress is not overwritten")
    tab.close()
    tab.busy = false
    tab.noteClients(listed: "ttys001|$6\n", epoch: tab.clientEpoch, now: now.addingTimeInterval(10))
    #expect(tab.shellSessionID == "$4")
  }
}

@MainActor
@Suite("what the menu runs")
struct TmuxCommandTests {
  @Test("attach is one line in this terminal, and a name cannot become a second command")
  func attachLine() {
    #expect(
      TmuxCommands.attachLine(name: "dev", id: "$1", window: nil)
        == "tmux attach-session -t 'dev'")
    #expect(
      TmuxCommands.attachLine(name: "dev", id: "$1", window: 4)
        == "tmux attach-session -t 'dev' \\; select-window -t @4")
    #expect(
      TmuxCommands.attachLine(name: "it's $(id)", id: "$1", window: nil)
        == "tmux attach-session -t 'it'\\''s $(id)'")
    #expect(
      TmuxCommands.attachLine(name: "bad\nname", id: "$1", window: nil)
        == "tmux attach-session -t '$1'",
      "a name that cannot be quoted falls back to the session id")
    #expect(TmuxCommands.attachLine(name: "bad\nname", id: "$(id)", window: nil) == nil)
    #expect(TmuxCommands.attachLine(name: "", id: "$2", window: nil) == "tmux attach-session -t '$2'")
  }

  @Test("a client that is already tmux is switched, not typed into")
  func switchClient() {
    #expect(
      TmuxCommands.switchClient(tty: "/dev/ttys001", session: "$3")
        == "tmux switch-client -c '/dev/ttys001' -t '$3'")
    #expect(TmuxCommands.switchClient(tty: "/dev/ttys001", session: "dev") == nil)
    #expect(TmuxCommands.switchClient(tty: "bad\ntty", session: "$1") == nil)
    #expect(TmuxCommands.newWindow("$1") == "tmux new-window -t '$1'")
    #expect(TmuxCommands.split("$1", horizontal: true) == "tmux split-window -h -t '$1'")
    #expect(TmuxCommands.split("$1", horizontal: false) == "tmux split-window -v -t '$1'")
    #expect(TmuxCommands.zoom("$1") == "tmux resize-pane -Z -t '$1'")
    #expect(TmuxCommands.detach(tty: "/dev/ttys001") == "tmux detach-client -t '/dev/ttys001'")
    #expect(TmuxCommands.renameWindow(2, to: "edit") == "tmux rename-window -t @2 'edit'")
    #expect(TmuxCommands.renameWindow(2, to: "bad\nname") == nil)
  }

}

@MainActor
@Suite("scrolling the shell's own client")
struct ShellScrollTests {
  @Test("the wheel asks that pane to scroll, and only a pane id is quoted")
  func command() {
    #expect(
      TmuxShellScroll.command(target: "%2", lines: 4)
        == TmuxShellCommand(
          text: "tmux copy-mode -e -t '%2' \\; send-keys -X -N 4 -t '%2' scroll-up",
          applied: 4))
    #expect(
      TmuxShellScroll.command(target: "%12", lines: -2)
        == TmuxShellCommand(
          text: "tmux send-keys -X -N 2 -t '%12' scroll-down", applied: -2))
    #expect(TmuxShellScroll.command(target: "%2", lines: 0) == nil)
    #expect(TmuxShellScroll.command(target: "$1", lines: 4) == nil)
    #expect(TmuxShellScroll.command(target: "dev", lines: 3) == nil)
    #expect(TmuxShellScroll.command(target: "%", lines: 3) == nil)
    #expect(TmuxShellScroll.command(target: "$(id)", lines: 3) == nil)
    #expect(TmuxShellScroll.command(target: "%1;id", lines: 3) == nil)
    #expect(TmuxShellScroll.command(target: "%2", lines: 900)?.applied == 500)
    #expect(TmuxShellScroll.command(target: "%2", lines: 900)?.text.contains("-N 500") == true)
    #expect(TmuxShellScroll.cancel(pane: "%2") == "tmux send-keys -X -t '%2' cancel")
    #expect(TmuxShellScroll.cancel(pane: "$0") == nil)
    #expect(TmuxShellScroll.cancel(pane: "dev") == nil)
  }

}

@MainActor
@Suite("which pane a reported wheel belongs to")
struct PaneWheelTests {
  private func panes(
    alternate: Bool = false, wantsMouse: Bool = false, inMode: Bool = false,
    statusTop: Bool = false, statusLines: Int = 1, zoomed: Bool = false
  ) -> [TmuxPaneWheel] {
    [
      TmuxPaneWheel(
        id: "%0", left: 0, top: 0, width: 80, height: zoomed ? 10 : 10,
        alternate: alternate, wantsMouse: wantsMouse, inMode: inMode,
        active: !zoomed, zoomed: zoomed, windowHeight: 19,
        statusLines: statusLines, statusTop: statusTop),
      TmuxPaneWheel(
        id: "%1", left: 0, top: zoomed ? 0 : 11, width: 80, height: zoomed ? 19 : 8,
        alternate: false, wantsMouse: false, inMode: false,
        active: true, zoomed: zoomed, windowHeight: 19,
        statusLines: statusLines, statusTop: statusTop),
    ]
  }

  @Test("a pane that asked for the mouse keeps the wheel, and one already copying keeps scrolling")
  func programsKeepTheWheel() {
    #expect(TmuxPaneLayout.decide(panes(wantsMouse: true), column: 1, row: 1) == .report)
    #expect(TmuxPaneLayout.decide(panes(alternate: true, wantsMouse: true), column: 1, row: 1) == .report)
    #expect(TmuxPaneLayout.decide(panes(alternate: true), column: 1, row: 1) == .stop)
    #expect(TmuxPaneLayout.decide(panes(alternate: true, inMode: true), column: 1, row: 1) == .scroll("%0"))
  }

  @Test("the layout command quotes only a session id, and a bad line is refused")
  func parsing() {
    #expect(TmuxPaneLayout.listCommand(session: "$1")?.hasPrefix("tmux list-panes -t '$1' -F ") == true)
    #expect(TmuxPaneLayout.listCommand(session: "dev") == nil)
    let line = "%0|0|0|80|10|0|0|0|1|0|19|bottom|on"
    let parsed = TmuxPaneLayout.parse(line)
    #expect(parsed?.count == 1)
    #expect(parsed?.first?.id == "%0")
    #expect(parsed?.first?.statusLines == 1)
    #expect(parsed?.first?.statusTop == false)
    #expect(TmuxPaneLayout.parse("%0|0|0|80|10|0|0|0|1|0|19|bottom|on\nbad") == nil)
    #expect(TmuxPaneLayout.parse("") == nil)
    #expect(TmuxPaneLayout.decide(parsed ?? [], column: 0, row: 3) == .scroll("%0"))
  }

  @Test("Files follows the active pane while a printed link uses its own pane")
  func paneDirectories() throws {
    let text = """
      %0|0|0|80|9|0|0|0|0|0|19|top|on|/srv/first | project
      %1|0|10|80|9|0|0|0|1|0|19|top|on|/srv/second
      """
    let entries = try #require(TmuxPaneDirectories.parse(text))
    #expect(TmuxPaneDirectories.directory(in: entries, for: nil) == "/srv/second")
    func link(row: UInt16) -> TerminalLink {
      TerminalLink(
        text: "out.csv", kind: .path(path: "out.csv", line: nil, column: nil),
        spans: [LinkSpan(row: row, start: 2, end: 9)])
    }
    #expect(TmuxPaneDirectories.directory(in: entries, for: link(row: 2)) == "/srv/first | project")
    #expect(TmuxPaneDirectories.directory(in: entries, for: link(row: 12)) == "/srv/second")
    #expect(TmuxPaneDirectories.directory(in: entries, for: link(row: 0)) == nil, "status line")
    #expect(TmuxPaneDirectories.directory(in: entries, for: link(row: 10)) == nil, "pane border")
    let switched = try #require(TmuxPaneDirectories.parse(text
      .replacingOccurrences(of: "|0|0|19|", with: "|1|0|19|")
      .replacingOccurrences(of: "%1|0|10|80|9|0|0|0|1|", with: "%1|0|10|80|9|0|0|0|0|")))
    #expect(TmuxPaneDirectories.directory(in: switched, for: nil) == "/srv/first | project")
    #expect(TmuxPaneDirectories.parse("bad") == nil)
    #expect(TmuxPaneDirectories.parse("") == nil)
    #expect(TmuxPaneDirectories.listCommand(session: "$2")?.contains("#{pane_current_path}") == true)
    #expect(TmuxPaneDirectories.listCommand(session: "$2'; touch /tmp/unsafe") == nil)
  }

  @Test("without a tty, a link is matched to the pane row that shows it")
  func paneSearch() throws {
    // Status on top: terminal row 12 is row 1 of the second pane.
    let entries = try #require(TmuxPaneDirectories.parse("""
      %0|0|0|80|9|0|0|0|0|0|19|top|on|/srv/first
      %1|0|10|80|9|0|0|0|1|0|19|top|on|/srv/second
      """))
    let cell = try #require(TmuxPaneSearch.cell(in: entries, column: 4, row: 12))
    #expect(cell.entry.directory == "/srv/second")
    #expect(cell.row == 1)
    #expect(TmuxPaneSearch.cell(in: entries, column: 4, row: 0) == nil, "status line")

    let wrapped = TerminalLink(
      text: "results/run-42/out.csv", kind: .path(path: "results/run-42/out.csv", line: nil, column: nil),
      spans: [LinkSpan(row: 3, start: 70, end: 80), LinkSpan(row: 4, start: 0, end: 12)])
    #expect(TmuxPaneSearch.fragment(of: wrapped) == "results/ru", "only what the first row draws")

    #expect(TmuxPaneSearch.captureCommand(pane: "%1", row: 1) == "tmux capture-pane -p -t '%1' -S 1 -E 1")
    #expect(TmuxPaneSearch.captureCommand(pane: "%1'; touch /tmp/unsafe", row: 1) == nil)
    #expect(TmuxPaneSearch.captureCommand(pane: "%1", row: -1) == nil)
  }
}
