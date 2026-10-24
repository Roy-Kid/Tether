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

  @Test("new terminal targets the current page; new tab creates another page")
  func creation() throws {
    let tabs = TabSet()
    let first = shell("a")
    tabs.adopt(first)
    let page = try #require(tabs.currentWorkspace)
    tabs.perform(.newTerminal)
    #expect(tabs.intent == .addTerminal(page.id))
    tabs.intent = nil
    tabs.perform(.newTab)
    #expect(tabs.intent == .newTab)
    let second = shell("b")
    tabs.adopt(second, in: page.id)
    #expect(tabs.visibleWorkspaces.count == 1)
    #expect(tabs.current?.id == second.id)
    #expect(tabs.currentTerminals.map(\.id) == [first.id, second.id])
    #expect(tabs.workspaceSplit == nil)
    tabs.adopt(shell("c"))
    #expect(tabs.visibleWorkspaces.count == 2)
    tabs.select(page.id)
    #expect(tabs.current?.id == second.id)
    #expect(tabs.tabs.count == 3)
  }

  @Test("a page's caption is what stands in for its shell — not the host, not a count")
  func caption() throws {
    let tabs = TabSet()
    tabs.adopt(shell("a"))
    let page = try #require(tabs.currentWorkspace)
    #expect(tabs.caption(for: page) == "", "the host bar already names the host")
    tabs.adopt(shell("b"), in: page.id)
    let grown = try #require(tabs.currentWorkspace)
    #expect(tabs.caption(for: grown) == "", "a second terminal does not turn it into a number")
  }

  @Test("pages on the same host keep independent layouts and focus")
  func isolation() throws {
    let tabs = TabSet()
    let a = shell("a"), b = shell("b"), hidden = shell("hidden"), c = shell("c")
    tabs.adopt(a)
    let first = try #require(tabs.currentWorkspace?.id)
    tabs.split(b, beside: a.id, direction: .right)
    tabs.adopt(hidden, in: first)
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .tab(hidden.id), 0.5))
    tabs.select(a.id)
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .tab(hidden.id), 0.5))
    tabs.adopt(c)
    #expect(tabs.workspaceSplit == nil)
    tabs.select(first)
    #expect(tabs.current?.id == a.id)
    tabs.select(b.id)
    #expect(tabs.workspaceSplit == .split(.right, .tab(b.id), .tab(hidden.id), 0.5))
    tabs.close(b.id, remember: false)
    #expect(tabs.current?.id == hidden.id)
    #expect(tabs.workspaces.count == 2)
    tabs.close(hidden.id, remember: false)
    tabs.close(a.id, remember: false)
    #expect(tabs.workspaces.count == 1)
    #expect(tabs.current?.id == c.id)
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

  @Test("context actions target the clicked page without any plugin")
  func contextTarget() throws {
    let tabs = TabSet()
    let a = shell("Same"), b = shell("Same")
    tabs.adopt(a)
    tabs.adopt(b, in: tabs.currentWorkspace!.id)
    let page = try #require(tabs.currentWorkspace?.id)
    tabs.adopt(shell("Other"))
    let menu = tabs.terminalMenu(for: a.id)
    #expect(menu[0].children.map(\.title) == ["Same 1 — Ended", "Same 2 — Ended"])
    #expect(menu[0].children[1].checked)
    menu.first { $0.title == "New Terminal" }?.action?()
    #expect(tabs.intent == .addTerminal(page))
    #expect(tabs.current?.id == a.id)
    #expect(tabs.accessories.isEmpty)
  }

}
