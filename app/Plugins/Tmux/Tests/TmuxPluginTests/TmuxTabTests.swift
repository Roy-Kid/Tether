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
  @Test("a session belongs to one tab: choosing it elsewhere brings its tab forward")
  func ownership() throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let firstID = UUID()
    let first = try #require(plugin.attach(to: host.context(firstID)) as? TmuxTab)
    let second = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    first.session = info("$1", "dev")
    first.showing = false

    second.choose(info("$1", "dev"), windowID: nil)

    #expect(host.focused == [firstID])
    #expect(first.showing)
    #expect(!second.showing, "the second tab did not attach a second client")
    #expect(second.session == nil)
    #expect(host.dismissed.count == 1, "the picker closes either way")
  }

  @Test("every tmux server has a $0: another host's is not this one")
  func ownershipIsPerHost() async throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let local = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    let remote = try #require(plugin.attach(to: host.context(host: UUID())) as? TmuxTab)
    local.session = info("$0", "main")

    remote.choose(info("$0", "main"), windowID: nil)

    #expect(host.focused.isEmpty, "nothing else owns the remote $0")
    #expect(!local.showing, "the local $0 is not the one chosen")
    // The remote tab attaches its own. It is shown once that attach has
    // worked — never before, so a failed attach leaves the shell in front —
    // and this probe has no connection for it to work with.
    #expect(remote.busy, "the remote tab went to attach it itself")
    for _ in 0..<50 where remote.busy { await Task.yield() }
    #expect(remote.error == "Not connected.")
    #expect(!remote.showing, "not shown before it is attached")
  }

  @Test("ending a session detaches the tab showing it, whichever tab asked")
  func endingDetachesTheOwner() throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let showing = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    let asking = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    showing.session = info("$1", "work")
    showing.showing = true

    asking.endSession(info("$1", "work"))

    #expect(showing.session == nil)
    #expect(!showing.isShowing)
  }

  @Test("the shell comes back without letting go of tmux")
  func shellKeepsAttachment() throws {
    let host = HostProbe()
    let tab = try #require(TmuxPlugin().attach(to: host.context()) as? TmuxTab)
    tab.session = info("$1", "dev")
    tab.showing = true
    #expect(tab.isShowing)
    #expect(tab.subtitle == "dev")

    tab.showShell()
    #expect(!tab.isShowing)
    #expect(tab.session?.id == "$1")
    #expect(tab.closeNote != nil, "closing the tab still leaves a session on the host")
  }

  @Test("nothing shows until there is a session to show")
  func showingNeedsASession() throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    tab.showing = true
    #expect(!tab.isShowing)
    #expect(tab.subtitle.isEmpty)
    #expect(tab.closeNote == nil)
    #expect(tab.commands.isEmpty)
  }

  @Test("detaching leaves the shell and offers nothing to detach")
  func detach() throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    tab.session = info("$1", "dev")
    tab.showing = true
    #expect(tab.commands.map(\.id).contains("detach"))

    tab.detachSession()
    #expect(!tab.isShowing)
    #expect(tab.session == nil)
    #expect(tab.commands.isEmpty)
  }

  @Test("a closed tab no longer owns its session")
  func closeForgets() throws {
    let host = HostProbe()
    let plugin = TmuxPlugin()
    let first = try #require(plugin.attach(to: host.context()) as? TmuxTab)
    first.session = info("$1", "dev")
    #expect(plugin.tab(owning: "$1", on: host.host) === first)

    first.close()
    #expect(plugin.tab(owning: "$1", on: host.host) == nil)
  }

  @Test("choosing the session this shell is already showing returns to that client")
  func choosingTheShellsSession() throws {
    let host = HostProbe()
    let tab = try #require(TmuxPlugin().attach(to: host.context()) as? TmuxTab)
    tab.shellSessionID = "$1"
    tab.session = info("$1", "dev")
    tab.showing = true

    tab.choose(info("$1", "dev"), windowID: nil)

    #expect(!tab.showing)
    #expect(tab.session == nil)
    #expect(host.dismissed.count == 1)
    #expect(!tab.busy, "the shell is the client, so nothing is attached")
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
    #expect(!tab.shellInputWaits)
    #expect(tab.error == nil)
  }
}

@MainActor
@Suite("pointing at a pane")
struct TmuxPaneLinkTests {
  @Test("a pane's links are answered by the tab, as the shell's are")
  func paneLinksGoToTheTab() async throws {
    var asked: [PointedLink] = []
    let context = TabContext(
      id: UUID(),
      plugin: PluginContext(
        connection: nil, hostLabel: "lab", hostID: UUID(),
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {},
      linkActions: { pointed in
        asked.append(pointed)
        return LinkActions(commands: [PluginCommand(id: "look", title: "Look", symbol: "eye") {}])
      })
    let tab = try #require(TmuxPlugin().attach(to: context) as? TmuxTab)
    let links = tab.links(for: 3)
    let link = TerminalLink(
      text: "out/plot.png", kind: .path(path: "out/plot.png", line: nil, column: nil),
      spans: [LinkSpan(row: 0, start: 0, end: 12)])

    #expect(links.find(0, 0) == nil, "no workspace, no pane text")
    #expect(links.menu(link)?.items.map(\.title) == ["Look"])
    let pointed = try #require(asked.first)
    #expect(pointed.link == link)
    #expect(await pointed.directory() == nil, "no workspace and no lease: nowhere to ask")
  }
}

/// What a pane does with each way of scrolling. "Jump to the present" and a
/// page key were dropped before, and only a wheel or a drag moved a pane.
@MainActor
@Suite("scrolling a pane")
struct PaneScrollTests {
  @Test("every request becomes lines of the pane's own history")
  func everyRequestScrolls() {
    #expect(TmuxContent.lines(for: .lines(3), page: 24) == 3)
    #expect(TmuxContent.lines(for: .pageUp, page: 24) == 23)
    #expect(TmuxContent.lines(for: .pageDown, page: 24) == -23)
    #expect(TmuxContent.lines(for: .live, page: 24) < -10_000, "all the way back to the present")
    #expect(TmuxContent.lines(for: .oldest, page: 24) > 10_000)
    #expect(TmuxContent.lines(for: .pageUp, page: 1) == 1, "a one-row pane still moves")
  }

  @Test("notches on one pane add up, and a return to zero is nothing to do")
  func notchesAddUp() {
    var steps = ScrollSteps()
    steps.add(pane: 1, lines: 3)
    steps.add(pane: 1, lines: 2)
    #expect(steps.values == [ScrollSteps.Step(pane: 1, lines: 5)])
    steps.add(pane: 1, lines: -5)
    #expect(steps.values.isEmpty)
    steps.add(pane: 1, lines: 0)
    #expect(steps.values.isEmpty)
    steps.add(pane: 1, lines: .max)
    steps.add(pane: 1, lines: 1)
    #expect(steps.values.first?.lines == .max)
  }

  @Test("a second pane stays its own step")
  func panesStaySeparate() {
    var steps = ScrollSteps()
    steps.add(pane: 1, lines: 4)
    steps.add(pane: 2, lines: -2)
    #expect(steps.values == [
      ScrollSteps.Step(pane: 1, lines: 4),
      ScrollSteps.Step(pane: 2, lines: -2),
    ])
    steps.add(pane: 1, lines: 1)
    #expect(steps.values.map(\.pane) == [1, 2, 1])
    #expect(steps.values.map(\.lines) == [4, -2, 1])
  }

  @Test("a wheel over a pane hits that pane")
  func wheelHitsThePane() {
    let pieces = TmuxContent.pieces(
      panes: [
        PaneBox(id: 1, x: 0, y: 0, width: 40, height: 20),
        PaneBox(id: 2, x: 40, y: 0, width: 40, height: 20),
      ],
      windowColumns: 80, windowRows: 20, cell: 10, line: 20, divider: 5)
    #expect(TmuxContent.paneID(at: CGPoint(x: 10, y: 10), in: pieces) == 1)
    #expect(TmuxContent.paneID(at: CGPoint(x: 410, y: 10), in: pieces) == 2)
    #expect(TmuxContent.paneID(at: CGPoint(x: -1, y: 10), in: pieces) == nil)
  }

  @Test("a pane's hit target is its grid, and the seam is only the shared edge")
  func piecesFollowTheGrid() {
    let pieces = TmuxContent.pieces(
      panes: [
        PaneBox(id: 1, x: 0, y: 0, width: 40, height: 20),
        PaneBox(id: 2, x: 40, y: 0, width: 40, height: 20),
      ],
      windowColumns: 80, windowRows: 20, cell: 10, line: 20, divider: 5)
    #expect(pieces.map(\.kind) == [.pane(1), .pane(2), .vertical(1)])
    #expect(pieces[0].frame == CGRect(x: 0, y: 0, width: 400, height: 400))
    #expect(pieces[1].frame == CGRect(x: 400, y: 0, width: 400, height: 400))
    #expect(pieces[2].frame == CGRect(x: 397.5, y: 0, width: 5, height: 400))
  }

  @Test("a pane that fills the window has no seam")
  func fullWindowHasNoDivider() {
    let pieces = TmuxContent.pieces(
      panes: [PaneBox(id: 7, x: 0, y: 0, width: 80, height: 24)],
      windowColumns: 80, windowRows: 24, cell: 10, line: 20, divider: 5)
    #expect(pieces.count == 1)
    #expect(pieces[0].kind == .pane(7))
    #expect(pieces[0].frame == CGRect(x: 0, y: 0, width: 800, height: 480))
  }

  @Test("free space under a pane belongs to that pane, so the last row is not the clip")
  func spareBelowStaysInThePane() {
    let pane = PaneBox(id: 7, x: 0, y: 0, width: 80, height: 24)
    let filled = TmuxContent.surfaceFrame(
      pane: pane, columns: 80, rows: 24, among: [pane], cell: 10, line: 20,
      view: CGSize(width: 2000, height: 2000))
    #expect(filled == CGRect(x: 0, y: 0, width: 2000, height: 2000))
    let exact = TmuxContent.surfaceFrame(
      pane: pane, columns: 80, rows: 24, among: [pane], cell: 10, line: 20,
      view: CGSize(width: 800, height: 480))
    #expect(exact == CGRect(x: 0, y: 0, width: 800, height: 480))
  }

  @Test("a pane stops at the next one, and a short view does not shrink the grid")
  func neighborsAndAShortView() {
    let upper = PaneBox(id: 1, x: 0, y: 0, width: 80, height: 12)
    let lower = PaneBox(id: 2, x: 0, y: 12, width: 80, height: 12)
    let top = TmuxContent.surfaceFrame(
      pane: upper, columns: 80, rows: 12, among: [upper, lower], cell: 10, line: 20,
      view: CGSize(width: 800, height: 1000))
    let bottom = TmuxContent.surfaceFrame(
      pane: lower, columns: 80, rows: 12, among: [upper, lower], cell: 10, line: 20,
      view: CGSize(width: 800, height: 1000))
    #expect(top == CGRect(x: 0, y: 0, width: 800, height: 240))
    #expect(bottom == CGRect(x: 0, y: 240, width: 800, height: 760))
    let short = TmuxContent.surfaceFrame(
      pane: upper, columns: 80, rows: 12, among: [upper], cell: 10, line: 20,
      view: CGSize(width: 800, height: 100))
    #expect(short.height == 240, "the grid stays whole; the view clips, the frame does not shrink")
  }

  @Test("a size that is still too tall keeps stepping down")
  func pointSizeKeepsShrinking() {
    #expect(TmuxContent.pointSize(asked: 13, scale: 1) { $0 <= 8 } == 8)
    #expect(TmuxContent.pointSize(asked: 13, scale: 2) { _ in true } == 13)
    #expect(TmuxContent.pointSize(asked: 13, scale: 0.2) { _ in false } == 5)
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
  }

  @Test("the wheel is claimed only for the shell that is already that client")
  func claimsOnlyTheKnownClient() {
    #expect(
      TmuxShellScroll.claims(
        showing: false, connected: true, session: "$1", tty: "/dev/ttys001",
        knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        showing: true, connected: true, session: "$1", tty: "/dev/ttys001",
        knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        showing: false, connected: false, session: "$1", tty: "/dev/ttys001",
        knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        showing: false, connected: true, session: "dev", tty: "/dev/ttys001",
        knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        showing: false, connected: true, session: "$1", tty: "/dev/ttys002",
        knownTTY: "/dev/ttys001"))
    #expect(
      !TmuxShellScroll.claims(
        showing: false, connected: true, session: nil, tty: "/dev/ttys001",
        knownTTY: "/dev/ttys001"))
  }

  @Test("opposite notches cancel, and a run that overflows stays in range")
  func notchesCancel() {
    var notches = ShellNotches()
    notches.add(4)
    notches.add(1)
    #expect(notches.take() == 5)
    #expect(notches.take() == 0)
    notches.add(.max)
    notches.add(1)
    #expect(notches.take() == .max)
    notches.add(3)
    notches.add(-3)
    #expect(notches.take() == 0)
  }
}
