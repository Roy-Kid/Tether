import Foundation
import SwiftUI
import Testing
import Tether
import TetherPluginKit

@testable import TmuxPlugin

/// A tab as the host would hand it over, recording what the plugin asked
/// the host to do. No connection: nothing here reaches a tmux server.
@MainActor
private final class HostProbe {
  var focused: [UUID] = []
  var dismissed: [UUID] = []
  let host = UUID()

  func context(_ id: UUID = UUID(), host: UUID? = nil) -> TabContext {
    TabContext(
      id: id,
      plugin: PluginContext(
        connection: nil, hostLabel: "lab", hostID: host ?? self.host,
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: { [unowned self] in focused.append(id) },
      dismissAccessory: { [unowned self] in dismissed.append(id) },
      present: { _ in },
      dismissSheet: {})
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

    #expect(host.focused.isEmpty, "the other terminal is left where it is")
    #expect(first.shellSessionID == "$1")
    for _ in 0..<50 where second.busy { await Task.yield() }
    #expect(second.error == "Not connected.")
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

  @Test("a shell that is a client keeps its name, and is what the menu offers")
  func shellClientIsTheMenu() throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    tab.shellSessionID = "$1"
    tab.sessions = [info("$1", "dev")]
    #expect(tab.subtitle == "dev")
    #expect(!tab.isShowing)
    #expect(tab.commands.map(\.id) == ["detach", "newWindow", "splitHorizontal", "splitVertical", "zoom"])
    #expect(tab.closeNote == "tmux stays on the host.")
  }

  @Test("nothing is offered until this terminal is a client")
  func menuNeedsAClient() throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    #expect(!tab.isShowing)
    #expect(tab.subtitle.isEmpty)
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
    #expect(host.dismissed.count == 1)
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
    #expect(!tab.scrollShell(3, fullScreen: true))
    #expect(!tab.scrollShell(3, fullScreen: false))
    #expect(!tab.claimWheel(3, column: 1, row: 2))
    #expect(!tab.shellInputWaits)
    #expect(tab.error == nil)
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
  @Test("the wheel asks that client to scroll, and only a real session id is quoted")
  func command() {
    #expect(
      TmuxShellScroll.command(session: "$1", lines: 4)
        == TmuxShellCommand(
          text: "tmux copy-mode -e -t '$1' \\; send-keys -X -N 4 -t '$1' scroll-up",
          applied: 4))
    #expect(
      TmuxShellScroll.command(session: "$12", lines: -2)
        == TmuxShellCommand(
          text: "tmux send-keys -X -N 2 -t '$12' scroll-down", applied: -2))
    #expect(TmuxShellScroll.command(session: "$1", lines: 0) == nil)
    #expect(TmuxShellScroll.command(session: "dev", lines: 3) == nil)
    #expect(TmuxShellScroll.command(session: "$", lines: 3) == nil)
    #expect(TmuxShellScroll.command(session: "$(id)", lines: 3) == nil)
    #expect(TmuxShellScroll.command(session: "$1;id", lines: 3) == nil)
    #expect(TmuxShellScroll.command(session: "$1", lines: 900)?.applied == 500)
    #expect(TmuxShellScroll.command(session: "$1", lines: 900)?.text.contains("-N 500") == true)
    #expect(TmuxShellScroll.cancel(session: "$0") == "tmux send-keys -X -t '$0' cancel")
    #expect(TmuxShellScroll.cancel(session: "dev") == nil)
    #expect(
      TmuxShellScroll.command(target: "%2", lines: 4)
        == TmuxShellCommand(
          text: "tmux copy-mode -e -t '%2' \\; send-keys -X -N 4 -t '%2' scroll-up",
          applied: 4))
    #expect(TmuxShellScroll.command(target: "%", lines: 3) == nil)
    #expect(TmuxShellScroll.command(target: "%1;id", lines: 3) == nil)
    #expect(TmuxShellScroll.command(session: "%2", lines: 3) == nil)
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

  @Test("a pane that asked for the mouse keeps the wheel, unless it is already copying")
  func programsKeepTheWheel() {
    #expect(TmuxPaneLayout.decide(panes(alternate: true), column: 1, row: 1) == .report)
    #expect(TmuxPaneLayout.decide(panes(wantsMouse: true), column: 1, row: 1) == .report)
    #expect(TmuxPaneLayout.decide(panes(alternate: true, inMode: true), column: 1, row: 1) == .scroll("%0"))
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
}
