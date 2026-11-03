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

  @Test("a session wears the mark a status plugin reports on one of its panes")
  func sessionDotComesFromItsPanes() throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let tab = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    defer { tab.close() }
    let work = info("$1", "work")
    let idle = info("$2", "idle")
    #expect(tab.indicator(for: work) == nil, "no panes read yet")
    #expect(host.askedMarks.isEmpty)

    tab.notePanes(listed: "/dev/ttys004 $1\n/dev/ttys005 $1\n/dev/ttys006 $2\nnot a pane\n")
    host.marks["/dev/ttys005"] = PluginTabIndicator(
      target: .init(host: "lab", terminal: "/dev/ttys005"), color: 0xFF9F0A, label: "Needs you")
    #expect(tab.indicator(for: work)?.label == "Needs you")
    #expect(host.askedMarks.last == ["/dev/ttys004", "/dev/ttys005"])
    #expect(tab.indicator(for: idle) == nil)
    #expect(host.askedMarks.last == ["/dev/ttys006"])

    // The tab shows its client's session; another tab on the host reads
    // the same panes without listing them again.
    #expect(tab.shownTerminals.isEmpty, "not a client yet")
    tab.shellSessionID = "$1"
    #expect(tab.shownTerminals == ["/dev/ttys004", "/dev/ttys005"])
    let other = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    defer { other.close() }
    #expect(other.paneTTYs(of: "$2") == ["/dev/ttys006"])
  }

  @Test("restore metadata keeps the session identity without retaining a client")
  func restorationMetadata() async throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let original = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    #expect(original.restorationState == nil)
    original.sessions = [info("$7", "work")]
    original.shellSessionID = "$7"
    let data = try #require(original.restorationState)
    let saved = try JSONDecoder().decode(TmuxTab.Restoration.self, from: data)
    #expect(saved.sessionID == "$7")
    #expect(saved.sessionName == "work")
    original.shellSessionID = nil
    #expect(original.restorationState == nil)
    original.close()

    let restored = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    defer { restored.close() }
    restored.restore(from: data)
    for _ in 0..<100 where restored.busy { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!restored.busy)
    #expect(restored.error != nil, "reopening needs a fresh lease; metadata cannot keep one alive")
    #expect(restored.shellSessionID == nil)
  }

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

  @Test("ending a session is not pretended when there is no lease")
  func endingNeedsALease() async throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let client = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    let asking = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    client.shellSessionID = "$1"

    asking.endSession(info("$1", "work"))

    for _ in 0..<50 where asking.busy { await Task.yield() }
    #expect(asking.error == "Not connected.")
    #expect(client.shellSessionID == "$1", "a client that was not killed stays a client")
  }

  @Test("renaming a shell tells the host, and an unchanged name does not")
  func shellRenameReachesTheHost() throws {
    let probe = HostProbe()
    let shell = UUID()
    let tab = try #require(TmuxPlugin().attach(to: probe.context()) as? TmuxTab)
    tab.rename(.shell(shell, "Terminal 1"), to: "  build  ")
    tab.rename(.shell(shell, "build"), to: "build")
    #expect(probe.renamed.count == 1)
    #expect(probe.renamed.first?.0 == shell)
    #expect(probe.renamed.first?.1 == "build")
  }

  @Test("a shell that is a client keeps its name, and is what the menu offers")
  func shellClientIsTheMenu() throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    tab.shellSessionID = "$1"
    tab.sessions = [info("$1", "dev")]
    #expect(tab.subtitle == "dev")
    #expect(tab.tabTitle == "dev")
    #expect(!tab.isShowing)
    #expect(tab.commands.map(\.id) == ["detach", "newWindow", "previousWindow", "nextWindow", "splitHorizontal", "splitVertical", "zoom",
      "focusLeft", "focusDown", "focusUp", "focusRight", "session1"])
    #expect(tab.closeNote == "tmux stays on the host.")
  }

  @Test("nothing is offered until this terminal is a client")
  func menuNeedsAClient() throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    #expect(!tab.isShowing)
    #expect(tab.subtitle.isEmpty)
    #expect(tab.tabTitle.isEmpty)
    #expect(tab.closeNote == nil)
    #expect(tab.commands.isEmpty)
  }

  @Test("detaching without a lease leaves the client in place")
  func detachNeedsALease() async throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    tab.shellSessionID = "$1"
    #expect(tab.commands.map(\.id).contains("detach"))

    tab.detachSession()
    for _ in 0..<50 where tab.busy { await Task.yield() }
    #expect(tab.error == "Not connected.")
    #expect(tab.shellSessionID == "$1")
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

  @Test("choosing the session this shell is already showing stays on it")
  func choosingTheShellsSession() throws {
    let host = HostProbe()
    let tab = try #require(TmuxPlugin().attach(to: host.context()) as? TmuxTab)
    tab.shellSessionID = "$1"

    tab.choose(info("$1", "dev"), windowID: nil)

    #expect(tab.shellSessionID == "$1")
    #expect(!tab.isShowing)
    #if os(macOS)
      #expect(host.dismissed.isEmpty, "the inspector stays open")
    #else
      #expect(host.dismissed.count == 1)
    #endif
    #expect(!tab.busy, "already there, so nothing is run")
  }

  @Test("without a lease an operation fails where it can be seen")
  func noLeaseIsAnError() async throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    tab.refresh()
    for _ in 0..<100 where tab.busy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(tab.error == "Not connected.")
  }

  @Test("a wheel is left with the shell until this one is known to be the client")
  func wheelWaitsForAKnownClient() throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    #expect(tab.claimWheel(3, column: 1, row: 2) == .pass)
    #expect(!tab.shellInputWaits)
    #expect(tab.error == nil)
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

  @Test("a refresh asked while busy runs once the operation finishes")
  func refreshWaitsForTheOperation() async throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let client = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    let shell = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    client.sessions = [info("$3", "kept")]

    shell.run { try await Task.sleep(for: .milliseconds(60)) }
    #expect(shell.busy)
    shell.refresh()
    #expect(shell.busy)
    #expect(shell.sessions.map(\.name) == ["kept"])

    for _ in 0..<100 where shell.busy { try await Task.sleep(for: .milliseconds(5)) }
    #expect(shell.error == "Not connected.")
    #expect(shell.sessions.map(\.name) == ["kept"])
  }

  @Test("refreshing keeps row positions while updating names, status and window indices")
  func refreshKeepsRowPositions() throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let tab = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    defer { tab.close() }
    let first = TmuxListedWindow(id: 9, index: 2, name: "zoo", active: true, panes: 1)
    let second = TmuxListedWindow(id: 7, index: 0, name: "apple", active: false, panes: 1)
    tab.store([
      TmuxSessionInfo(id: "$2", name: "zoo", attached: false, windows: [first, second]),
      info("$1", "apple"), info("$3", "ending"),
    ])
    #expect(tab.listedSessions.map(\.id) == ["$2", "$1", "$3"])
    #expect(tab.windows(for: tab.sessions[0]).map(\.id) == [9, 7])

    let renamed = TmuxListedWindow(id: 9, index: 8, name: "renamed", active: false, panes: 3)
    let activated = TmuxListedWindow(id: 7, index: 1, name: "apple", active: true, panes: 2)
    let added = TmuxListedWindow(id: 10, index: 0, name: "new", active: false, panes: 1)
    tab.store([
      info("$4", "aaa"), info("$1", "apple"),
      TmuxSessionInfo(id: "$2", name: "zzz", attached: true, windows: [added, activated, renamed]),
    ])
    #expect(tab.listedSessions.map(\.id) == ["$2", "$1", "$4"])
    #expect(tab.sessions[0].name == "zzz")
    #expect(tab.sessions[0].attached)
    #expect(tab.windows(for: tab.sessions[0]) == [renamed, activated, added])
    #expect(tab.commands.map(\.title) == ["zzz", "apple", "aaa"])

    // A new tab follows the host's existing positions on its first read.
    let other = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    defer { other.close() }
    other.store([
      info("$4", "aaa"), info("$1", "apple"),
      TmuxSessionInfo(id: "$2", name: "zzz", attached: true, windows: [added, activated]),
    ])
    #expect(other.listedSessions.map(\.id) == ["$2", "$1", "$4"])
    #expect(other.windows(for: other.sessions[0]) == [activated, added])

    other.store([])
    #expect(other.listedSessions.isEmpty)
    #expect(other.sessionsLoaded)
    other.store([info("$1", "apple"), info("$2", "zzz")])
    #expect(other.listedSessions.map(\.id) == ["$1", "$2"])
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

  @Test("a client list names the session, and a missing server is not an empty one")
  func clientList() {
    #expect(TmuxClients.session(for: "/dev/ttys001", in: "/dev/ttys001|$2\n") == "$2")
    #expect(TmuxClients.session(for: "/dev/ttys001", in: "ttys001|$9\n") == "$9")
    #expect(TmuxClients.session(for: "/dev/ttys001", in: "/dev/ttys002|$3\n") == nil)
    #expect(TmuxClients.session(for: "/dev/ttys001", in: "not a client\n") == nil)
    let clients = Data("/dev/ttys001|$2\n".utf8)
    #expect(TmuxClients.listing(status: 0, stdout: clients, stderr: Data()) == "/dev/ttys001|$2\n")
    #expect(TmuxClients.listing(status: 1, stdout: Data(), stderr: Data("no clients\n".utf8)) == "")
    #expect(TmuxClients.listing(status: 1, stdout: Data(), stderr: Data("no server running\n".utf8)) == nil)
    #expect(TmuxClients.listing(status: 127, stdout: Data(), stderr: Data("No such file or directory\n".utf8)) == nil)
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

  @Test("focus moves between panes and windows of the session on this terminal")
  func paneAndWindowFocus() {
    #expect(TmuxCommands.selectPane("$1", .left) == "tmux select-pane -L -t '$1'")
    #expect(TmuxCommands.selectPane("$1", .down) == "tmux select-pane -D -t '$1'")
    #expect(TmuxCommands.selectPane("$1", .up) == "tmux select-pane -U -t '$1'")
    #expect(TmuxCommands.selectPane("$1", .right) == "tmux select-pane -R -t '$1'")
    #expect(TmuxCommands.selectPane("$(id)", .left) == nil)
    #expect(TmuxCommands.cycleWindow("$1", forward: true) == "tmux next-window -t '$1'")
    #expect(TmuxCommands.cycleWindow("$1", forward: false) == "tmux previous-window -t '$1'")
    #expect(TmuxCommands.cycleWindow("dev", forward: true) == nil)
  }

  @Test("every command a client offers is catalogued, with the chords spec §4 gives tmux")
  func catalogue() throws {
    let plugin = TmuxPlugin()
    let tab = try #require(plugin.attach(to: HostProbe().context()) as? TmuxTab)
    defer { tab.close() }
    #expect(tab.commands.isEmpty, "a shell with no session list offers nothing")
    tab.sessions = [info("$0", "alpha"), info("$1", "beta")]
    #expect(tab.commands.map(\.id) == ["session1", "session2"], "⌥1 works before the shell has entered tmux")
    tab.shellSessionID = "$1"
    let descriptors = plugin.commandDescriptors
    let standing = descriptors.filter { !$0.id.hasPrefix("session") }
    #expect(tab.commands.map(\.id).starts(with: standing.map(\.id)))
    #expect(tab.commands.suffix(2).map(\.id) == ["session1", "session2"])
    #expect(tab.commands.suffix(2).map(\.title) == ["alpha", "beta"])
    let chords = Dictionary(uniqueKeysWithValues: descriptors.compactMap { d in d.shortcut.map { (d.id, $0) } })
    #expect(Set(chords.values).count == chords.count, "no two tmux commands share a chord")
    #expect(chords["detach"] == nil)
    #expect(chords["session1"] == PluginKeyChord("1", [.option]))
    #expect(chords["session4"] == PluginKeyChord("4", [.option]))
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

  @Test("a tty that is not a client returns the wheel to history only while the mouse is free")
  func release() {
    #expect(TmuxShellScroll.returnsToHistory(.off))
    #expect(!TmuxShellScroll.returnsToHistory(.clicks))
  }

  @Test("the wheel is claimed only for the shell that is already that client")
  func claimsOnlyTheKnownClient() {
    #expect(
      TmuxShellScroll.claims(
        connected: true, session: "$1", tty: "/dev/ttys001", knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        connected: false, session: "$1", tty: "/dev/ttys001", knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        connected: true, session: "dev", tty: "/dev/ttys001", knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        connected: true, session: "$1", tty: "/dev/ttys002", knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        connected: true, session: nil, tty: "/dev/ttys001", knownTTY: "/dev/ttys001"))
  }

  @Test("a wheel is held only while this tty might still be the client")
  func holdsWhileUnsettled() {
    #expect(
      TmuxShellScroll.holds(
        connected: true, tty: "/dev/ttys001", knownTTY: nil, session: nil, lookupRunning: true))
    #expect(
      !TmuxShellScroll.holds(
        connected: true, tty: "/dev/ttys001", knownTTY: "/dev/ttys001",
        session: nil, lookupRunning: true),
      "a settled no keeps the terminal's own history")
    #expect(
      !TmuxShellScroll.holds(
        connected: true, tty: "/dev/ttys001", knownTTY: nil, session: nil, lookupRunning: false))
  }

  @Test("opposite notches cancel, and a run that overflows stays in range")
  func notchesCancel() {
    var notches = ShellNotches()
    notches.add(4)
    notches.add(1)
    #expect(notches.take().lines == 5)
    #expect(notches.take().lines == 0)
    notches.add(.max)
    notches.add(1)
    #expect(notches.take().lines == .max)
    notches.add(3)
    notches.add(-3)
    #expect(notches.take().lines == 0)
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

  @Test("a shell pane scrolls by the pointer, and the status line does not")
  func shellScrolls() {
    let layout = panes()
    #expect(TmuxPaneLayout.decide(layout, column: 4, row: 5) == .scroll("%0"))
    #expect(TmuxPaneLayout.decide(layout, column: 4, row: 15) == .scroll("%1"))
    #expect(TmuxPaneLayout.decide(layout, column: 4, row: 10) == .ignore)
    #expect(TmuxPaneLayout.decide(layout, column: 4, row: 19) == .ignore)
  }

  @Test("a pane that asked for the mouse keeps the wheel, and one already copying keeps scrolling")
  func programsKeepTheWheel() {
    #expect(TmuxPaneLayout.decide(panes(wantsMouse: true), column: 1, row: 1) == .report)
    #expect(TmuxPaneLayout.decide(panes(alternate: true, wantsMouse: true), column: 1, row: 1) == .report)
    #expect(TmuxPaneLayout.decide(panes(alternate: true), column: 1, row: 1) == .stop)
    #expect(TmuxPaneLayout.decide(panes(alternate: true, inMode: true), column: 1, row: 1) == .scroll("%0"))
  }

  @Test("the cell under the pointer is the only layer that moves")
  func oneLayer() {
    #expect(TmuxPaneLayout.claim(panes(), column: 4, row: 5) == .taken)
    #expect(TmuxPaneLayout.claim(panes(), column: 4, row: 19) == .taken)
    #expect(TmuxPaneLayout.claim(panes(wantsMouse: true), column: 1, row: 1) == .report)
    #expect(TmuxPaneLayout.claim(panes(alternate: true), column: 1, row: 1) == .taken)
  }

  @Test("a zoomed window scrolls only the pane that is showing")
  func zoomShowsOnePane() {
    #expect(TmuxPaneLayout.decide(panes(zoomed: true), column: 1, row: 5) == .scroll("%1"))
  }

  @Test("a status line on top is not a pane row")
  func statusOnTop() {
    let layout = panes(statusTop: true)
    #expect(TmuxPaneLayout.decide(layout, column: 1, row: 0) == .ignore)
    #expect(TmuxPaneLayout.decide(layout, column: 1, row: 1) == .scroll("%0"))
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
