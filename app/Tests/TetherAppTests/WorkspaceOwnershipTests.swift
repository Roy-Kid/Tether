import SwiftUI
import Testing
import Tether
import TetherPluginKit

@testable import TetherApp

import struct TetherApp.Host

/// Each test gets local preferences that cannot change another test or the app.
private final class WorkspacePreferences {
  let name = "Tether.WorkspaceTests.\(UUID())"
  let defaults: UserDefaults

  init() { defaults = UserDefaults(suiteName: name)! }
  deinit { defaults.removePersistentDomain(forName: name) }
}

@MainActor
@Suite("Workspace ownership")
struct WorkspaceOwnershipTests {
  private let preferences = WorkspacePreferences()

  private func makeTabs() -> TabSet {
    TabSet(defaults: preferences.defaults)
  }

  private func tab(_ host: Host, name: String, live: Bool = true) -> SessionTab {
    SessionTab(preview: host, known: KnownHosts(), name: name, live: live)
  }

  @Test("closing the last tab in the window reports an empty window")
  func closeLastReportsEmpty() {
    let tabs = makeTabs()
    var emptied = 0
    tabs.onEmptied = { emptied += 1 }
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.adopt(tab(.local, name: "Terminal 2", live: false))
    tabs.close(tabs.tabs[0].id)
    #expect(emptied == 0)
    tabs.close(tabs.tabs[0].id)
    #expect(emptied == 1)
    #expect(tabs.tabs.isEmpty)
  }

  @Test("a live tab with unknown process state asks before closing")
  func liveTabConfirms() async {
    let tabs = makeTabs()
    tabs.adopt(tab(.local, name: "Terminal 1", live: true))
    let id = tabs.selected!
    tabs.requestClose(id)
    while tabs.checkingClose != nil { await Task.yield() }
    #expect(tabs.pendingClose == id)
    #expect(tabs.tabs.count == 1)
    tabs.confirmClose()
    #expect(tabs.tabs.isEmpty)
  }

  @Test("an extension workspace asks before closing, and is named")
  func extensionConfirms() {
    let tabs = makeTabs()
    let workspace = StubWorkspace(title: "tmux \u{00B7} dev")
    tabs.currentHost = .local
    tabs.openExtension(workspace, pluginID: "test", hostID: Host.localID)
    let id = tabs.selected!
    tabs.requestClose(id)
    #expect(tabs.pendingClose == id)
    #expect(tabs.closeQuestion == "Close tmux \u{00B7} dev?")
    #expect(tabs.extensions.count == 1)
    tabs.confirmClose()
    #expect(tabs.extensions.isEmpty)
    #expect(workspace.closed)
  }

  @Test("⌘W closes a selector before the tab")
  func closeSelectorFirst() {
    let tabs = makeTabs()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.tabMenu = tabs.selected
    tabs.requestCloseSelected()
    #expect(tabs.tabMenu == nil)
    #expect(tabs.tabs.count == 1)
    tabs.palette = .command
    tabs.requestCloseSelected()
    #expect(tabs.palette == nil)
    #expect(tabs.tabs.count == 1)
  }

  #if os(macOS)

  #endif

  @Test("what a plugin shows stands in for the shell, and names itself")
  func attachmentStandsInForShell() throws {
    let tabs = makeTabs()
    let first = tab(.local, name: "Terminal 1")
    tabs.adopt(first)
    let attached = StubAttachment(subtitle: "dev / editor")
    first.attach(attached, for: "test.tab")
    #expect(first.shown == nil, "attached is not showing")
    #expect(first.subtitle.isEmpty)

    attached.isShowing = true
    #expect(first.shown === attached)
    #expect(first.subtitle == "dev / editor")
    #expect(tabs.caption(for: try #require(tabs.currentWorkspace)) == "dev / editor", "the tab's caption")
    #expect(tabs.workspaceCaption(for: .local) == "Local machine · Terminal 1 / dev / editor")
    #expect(tabs.statusLine().isEmpty)

    attached.isDisconnected = true
    #expect(tabs.statusLine() == "Disconnected")
  }

  @Test("closing a tab closes what plugins kept on it")
  func closingTabClosesAttachments() {
    let tabs = makeTabs()
    let first = tab(.local, name: "Terminal 1")
    tabs.adopt(first)
    let attached = StubAttachment()
    first.attach(attached, for: "test.tab")
    tabs.close(first.id)
    #expect(attached.closed)
  }

  @Test("turning a plugin off takes it off every tab")
  func disablingDetaches() {
    let tabs = makeTabs()
    let first = tab(.local, name: "Terminal 1")
    let second = tab(.local, name: "Terminal 2")
    tabs.adopt(first)
    tabs.adopt(second)
    let one = StubAttachment()
    let two = StubAttachment()
    let other = StubAttachment()
    first.attach(one, for: "test.tab")
    second.attach(two, for: "test.tab")
    second.attach(other, for: "test.other")
    tabs.toggleAccessory("test.tab", on: second.id)

    tabs.closePlugin("test.tab")
    #expect(one.closed && two.closed)
    #expect(!other.closed)
    #expect(first.attachment(for: "test.tab") == nil)
    #expect(second.attachment(for: "test.other") != nil)
    #expect(tabs.accessory == nil)
  }

  @Test("clicking another tab, or cycling, switches to it")
  func clickAndCycleSwitchTabs() {
    let tabs = makeTabs()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.adopt(tab(.local, name: "Terminal 2"))
    let ids = tabs.visibleIDs
    #expect(ids.count == 2)
    #expect(tabs.selectedWorkspaceID == ids[1])

    tabs.handleTabClick(ids[0])
    #expect(tabs.selectedWorkspaceID == ids[0])
    tabs.perform(.nextTab)
    #expect(tabs.selectedWorkspaceID == ids[1])
    tabs.perform(.previousTab)
    #expect(tabs.selectedWorkspaceID == ids[0])
  }

  @Test("clicking the selected tab opens the first accessory")
  func selectedTabClickOpensAccessory() {
    let tabs = makeTabs()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    let id = tabs.selected!
    tabs.handleTabClick(id)
    #expect(tabs.accessory == nil, "no tab plugin, nothing to open")

    tabs.accessories = [
      PluginAccessory(
        id: "test.tab", title: "Test",
        accessory: TabAccessory(symbol: "star", name: "test things"))
    ]
    tabs.handleTabClick(id)
    #expect(tabs.accessory == nil, "no lease and nothing attached: an empty popover")

    // An attachment keeps its accessory open to a tab whose own shell has
    // no lease — the state a reconnect leaves behind.
    tabs.current?.attach(StubAttachment(), for: "test.tab")
    tabs.handleTabClick(id)
    #expect(tabs.accessory == AccessoryRef(tab: id, plugin: "test.tab"))
    tabs.handleTabClick(id)
    #expect(tabs.accessory == nil)
  }

  #if os(macOS)
  #endif

  @Test("an accessory kept beside the terminal opens the inspector, not a popover")
  func inspectorAccessoryTogglesTheInspector() {
    let tabs = makeTabs()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    let id = tabs.selected!
    tabs.accessories = [
      PluginAccessory(
        id: "test.files", title: "Files",
        accessory: TabAccessory(symbol: "folder", name: "Files", placement: .inspector))
    ]
    tabs.current?.attach(StubAttachment(), for: "test.files")

    tabs.toggleAccessory("test.files", on: id)
    #if os(macOS)
      #expect(tabs.accessory == nil, "no popover")
      #expect(tabs.inspector)
      #expect(tabs.inspectorPlugin == "test.files")
      #expect(tabs.isShowingInspector(of: "test.files"))

      tabs.toggleAccessory("test.files", on: id)
      #expect(!tabs.inspector)
      #expect(tabs.inspectorPlugin == nil)
    #else
      // A phone has no inspector: the same content opens as a sheet.
      #expect(tabs.accessory == AccessoryRef(tab: id, plugin: "test.files"))
    #endif
  }

  @Test("something asked for from the terminal brings the accessory up, and never closes it")
  func showAccessoryNeverCloses() {
    let tabs = makeTabs()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    let id = tabs.selected!
    tabs.accessories = [
      PluginAccessory(
        id: "test.files", title: "Files",
        accessory: TabAccessory(symbol: "folder", name: "Files", placement: .inspector)),
      PluginAccessory(
        id: "test.tab", title: "Test", accessory: TabAccessory(symbol: "star", name: "things")),
    ]
    tabs.showAccessory("test.files", on: id)
    tabs.showAccessory("test.files", on: id)
    #if os(macOS)
      #expect(tabs.isShowingInspector(of: "test.files"))
    #else
      #expect(tabs.accessory == AccessoryRef(tab: id, plugin: "test.files"))
    #endif
    tabs.showAccessory("test.tab", on: id)
    tabs.showAccessory("test.tab", on: id)
    #expect(tabs.accessory == AccessoryRef(tab: id, plugin: "test.tab"))
  }

  #if os(macOS)

  #endif

  @Test("a dropped host comes back on one lease; an ended shell does not")
  func droppedTerminalsShareOneLease() {
    let tabs = makeTabs()
    let lab = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: nil)
    let other = Host(label: "other", hostname: "other.example", port: 22, username: "ada", keyPath: nil)
    let dropped = tab(lab, name: "Terminal 1", live: false)
    let ended = tab(lab, name: "Terminal 2", live: false)
    let elsewhere = tab(other, name: "Terminal 1", live: false)
    let local = tab(.local, name: "Terminal 1", live: false)
    dropped.finish(.lost(cause: "reset by peer"))
    elsewhere.finish(.lost(cause: "reset by peer"))
    local.finish(.lost(cause: "gone"))
    tabs.adopt(dropped)
    tabs.adopt(ended)
    tabs.adopt(elsewhere)
    tabs.adopt(local)

    #expect(tabs.sessionsToRestore(on: lab).map(\.id) == [dropped.id])
    #expect(tabs.sessionsToRestore(on: .local).isEmpty)
    #expect(tabs.reconnectLeader(for: lab, besides: dropped.id) == nil,
      "a dropped terminal is not a login to join")
  }

  @Test("status names a problem, not a kind")
  func statusNamesAProblem() {
    let tabs = makeTabs()
    tabs.adopt(tab(.local, name: "Terminal 1", live: false))
    #expect(tabs.statusLine() == "Ended")
  }

}
