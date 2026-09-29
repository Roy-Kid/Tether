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

  @Test("without a lease an operation fails where it can be seen")
  func noLeaseIsAnError() async throws {
    let tab = try #require(TmuxPlugin().attach(to: HostProbe().context()) as? TmuxTab)
    tab.refresh()
    for _ in 0..<100 where tab.busy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(tab.error == "Not connected.")
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
}
