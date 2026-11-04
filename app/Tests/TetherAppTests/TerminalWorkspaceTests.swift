import Foundation
import Testing
import TetherUI
@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Workspace tabs own multiple terminals")
struct TerminalWorkspaceTests {
  private func shell(_ name: String, host: Host = .local, live: Bool = false) -> SessionTab {
    SessionTab(preview: host, known: KnownHosts(location: URL(fileURLWithPath: "/dev/null")), name: name, live: live)
  }

  private func settle(_ tabs: TabSet) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while tabs.checkingClose != nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(tabs.checkingClose == nil)
  }

  @Test("a terminal cannot be attached to a page belonging to another host")
  func hostBoundary() throws {
    let tabs = TabSet()
    tabs.adopt(shell("local"))
    let page = try #require(tabs.currentWorkspace?.id)
    let remote = Host(label: "remote", hostname: "example.invalid", port: 22, username: "test")
    tabs.adopt(shell("remote", host: remote), in: page)
    #expect(tabs.tabs.count == 1)
    #expect(tabs.currentHost?.isLocal == true)
  }

  @Test("page close checks all shells and cancellation closes none")
  func closePage() async throws {
    var inspected: [String] = []
    let tabs = TabSet(inspectActivity: { tab in
      inspected.append(tab.name)
      return tab.name == "busy" ? .running(["sleep"]) : .idle
    })
    let a = shell("idle", live: true), b = shell("busy", live: true)
    tabs.adopt(a)
    let page = try #require(tabs.currentWorkspace?.id)
    tabs.adopt(b, in: page)
    tabs.requestCloseSelected()
    try await settle(tabs)
    #expect(inspected == ["idle", "busy"])
    #expect(tabs.pendingClose == page)
    #expect(tabs.closeQuestion.contains("Tab"))
    #expect(tabs.closeNote?.contains("sleep") == true)
    tabs.cancelClose()
    #expect(tabs.tabs.count == 2)
    tabs.requestCloseWorkspace(page)
    try await settle(tabs)
    tabs.confirmClose()
    #expect(tabs.tabs.isEmpty)
    #expect(tabs.workspaces.isEmpty)
    #expect(tabs.closedTabs.count == 1)
    #expect(tabs.closedTabs[0].members.map(\.name) == ["idle", "busy"])
  }

  @Test("closing one pane of a split asks about that pane only")
  func closeOnePane() async throws {
    let tabs = TabSet(inspectActivity: { _ in .unknown })
    let a = shell("Terminal 1", live: true), b = shell("Terminal 2", live: true)
    tabs.adopt(a)
    let page = try #require(tabs.currentWorkspace?.id)
    tabs.split(b, beside: a.id, direction: .right)
    tabs.requestCloseFromTabBar(page)
    try await settle(tabs)
    #expect(tabs.closingWorkspaceID == nil)
    #expect(tabs.pendingClose == b.id, "the chip for the page closes the pane in front")
    #expect(tabs.closeQuestion == "Close Terminal 2?")
    #expect(tabs.closeNote == ShellActivity.unknown.closeMessage)
    tabs.cancelClose()
    tabs.requestCloseFromTabBar(a.id)
    try await settle(tabs)
    #expect(tabs.pendingClose == a.id)
    #expect(tabs.closeQuestion == "Close Terminal 1?")
    #expect(tabs.tabs.map(\.name) == ["Terminal 1", "Terminal 2"])
    tabs.confirmClose()
    #expect(tabs.tabs.map(\.name) == ["Terminal 2"])
    #expect(tabs.workspaces.map(\.id) == [page])
    #expect(tabs.workspaceSplit == nil)
  }

  @Test("aggregate history survives restart and remaps layout to fresh shell IDs")
  func restoration() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionHistoryStore(directory: directory)
    let tabs = TabSet(historyStore: store)
    let a = shell("a"), b = shell("b"), hidden = shell("hidden")
    tabs.adopt(a)
    let page = try #require(tabs.currentWorkspace?.id)
    tabs.split(b, beside: a.id, direction: .down)
    tabs.adopt(hidden, in: page)
    tabs.select(a.id)
    tabs.rename(page, to: "Project")
    tabs.closeWorkspace(page)
    let archived = try #require(tabs.closedTabs.last)
    for id in archived.historyIDs { #expect(FileManager.default.fileExists(atPath: store.location(id).path)) }
    let reopened = TabSet(historyStore: SessionHistoryStore(directory: directory))
    reopened.requestRestoreTab()
    let fresh = shell(archived.name)
    #expect(reopened.completeRestore(archived.id, with: fresh, makeTerminal: { shell($0.name) }))
    let restored = try #require(reopened.currentWorkspace)
    #expect(restored.name == "Project")
    #expect(restored.terminalIDs.count == 3)
    #expect(restored.focused == fresh.id)
    #expect(restored.layout == .split(.down, .tab(fresh.id), .tab(restored.terminalIDs[2]), 0.5))
    #expect(Set(restored.terminalIDs).isDisjoint(with: archived.members.map(\.id)))
    #expect(reopened.closedTabs.isEmpty)
    for id in archived.historyIDs { #expect(FileManager.default.fileExists(atPath: store.location(id).path)) }
  }

  @Test("dragging a tab reorders the strip and leaves each page its own")
  func reorderDoesNotMerge() throws {
    let tabs = TabSet()
    let a = shell("a"), b = shell("b"), c = shell("c")
    tabs.adopt(a)
    tabs.adopt(b)
    tabs.adopt(c)
    let ids = tabs.workspaces.map(\.id)
    #expect(tabs.reorder(c.id, beside: a.id, before: true))
    #expect(tabs.workspaces.map(\.terminalIDs) == [[c.id], [a.id], [b.id]])
    #expect(tabs.workspaces.map(\.id) == [ids[2], ids[0], ids[1]])
    #expect(tabs.workspaces.allSatisfy { $0.layout == nil && $0.terminalIDs.count == 1 })
    #expect(tabs.selected == c.id)
    #expect(!tabs.reorder(c.id, beside: c.id, before: false))
  }

  @Test("dragging inside a split only reorders that page's chips")
  func reorderInsideSplit() throws {
    let tabs = TabSet()
    let a = shell("a"), b = shell("b"), c = shell("c")
    tabs.adopt(a)
    tabs.split(b, beside: a.id, direction: .right)
    let page = try #require(tabs.workspace(containing: a.id))
    tabs.adopt(c)
    #expect(tabs.reorder(b.id, beside: a.id, before: true))
    let split = try #require(tabs.workspace(containing: a.id))
    #expect(split.id == page.id)
    #expect(split.terminalIDs == [b.id, a.id])
    #expect(split.layout == page.layout)
    #expect(tabs.workspaces.map(\.terminalIDs) == [[b.id, a.id], [c.id]])
  }

  @Test("dragging one pane out of a split makes its own page")
  func reorderExtractsPane() throws {
    let tabs = TabSet()
    let a = shell("a"), b = shell("b"), c = shell("c")
    tabs.adopt(a)
    tabs.split(b, beside: a.id, direction: .right)
    let page = try #require(tabs.workspace(containing: a.id)?.id)
    tabs.adopt(c)
    #expect(tabs.reorder(b.id, beside: c.id, before: true))
    #expect(tabs.workspaces.map(\.terminalIDs) == [[a.id], [b.id], [c.id]])
    #expect(tabs.workspaces.map(\.id)[0] == page)
    #expect(tabs.workspace(containing: a.id)?.layout == nil)
    #expect(tabs.workspace(containing: a.id)?.focused == a.id)
    #expect(tabs.workspace(containing: b.id)?.id != tabs.workspace(containing: c.id)?.id)
    #expect(tabs.selected == b.id)
  }

  @Test("a tab from another host stays where it is")
  func reorderHostBoundary() {
    let tabs = TabSet()
    tabs.adopt(shell("local"))
    let local = tabs.tabs[0].id
    let remote = Host(label: "remote", hostname: "example.invalid", port: 22, username: "test")
    tabs.adopt(shell("remote", host: remote))
    let remoteID = tabs.tabs[1].id
    let before = tabs.workspaces.map(\.terminalIDs)
    #expect(!tabs.reorder(remoteID, beside: local, before: true))
    #expect(tabs.workspaces.map(\.terminalIDs) == before)
  }

  @Test("dropping a tab on a pane still merges the two")
  func placeStillMerges() throws {
    let tabs = TabSet()
    let a = shell("a"), b = shell("b")
    tabs.adopt(a)
    tabs.adopt(b)
    #expect(tabs.place(b.id, beside: a.id, edge: .right))
    #expect(tabs.workspaces.count == 1)
    #expect(tabs.workspaces[0].terminalIDs == [a.id, b.id])
    #expect(tabs.workspaces[0].layout == .split(.right, .tab(a.id), .tab(b.id), 0.5))
  }

  @Test("v1 history becomes a single-terminal page")
  func legacyHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionHistoryStore(directory: directory)
    let record = ClosedTerminal(shell("Legacy"), index: 0)
    var manifest = SessionHistoryStore.Manifest(closed: [record], open: [])
    manifest.version = 1
    try JSONEncoder().encode(manifest).write(to: directory.appending(path: "tabs.json"))
    let tabs = TabSet(historyStore: store)
    tabs.requestRestoreTab()
    #expect(tabs.completeRestore(record.id, with: shell(record.name)))
    #expect(tabs.workspaces.count == 1)
    #expect(tabs.currentTerminals.count == 1)
    #expect(tabs.currentWorkspace?.name == "Legacy")
  }

}
