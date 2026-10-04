import SwiftUI
import Testing
import Tether
import TetherPluginKit

@testable import TetherApp

import struct TetherApp.Host

@MainActor
@Suite("Workspace ownership")
struct WorkspaceOwnershipTests {
  private func tab(_ host: Host, name: String, live: Bool = true) -> SessionTab {
    SessionTab(preview: host, known: KnownHosts(), name: name, live: live)
  }

  @Test("switching host restores that host's last tab")
  func hostSwitchRestores() {
    let tabs = TabSet()
    let lab = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: nil)
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.adopt(tab(lab, name: "Terminal 1"))
    #expect(tabs.currentHost?.id == lab.id)
    #expect(tabs.current?.name == "Terminal 1")
    #expect(tabs.visibleTabs.count == 1)

    tabs.show(.local)
    #expect(tabs.currentHost?.id == Host.localID)
    #expect(tabs.current?.host.id == Host.localID)

    tabs.show(lab)
    #expect(tabs.current?.host.id == lab.id)
  }

  @Test("closing the last tab in the window reports an empty window")
  func closeLastReportsEmpty() {
    let tabs = TabSet()
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

  @Test("closing the last tab on a host stays on that host")
  func closeLastStays() {
    let tabs = TabSet()
    let lab = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: nil)
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.adopt(tab(lab, name: "Terminal 1", live: false))
    tabs.close(tabs.selected!)
    #expect(tabs.currentHost?.id == lab.id)
    #expect(tabs.visibleTabs.isEmpty)
    #expect(tabs.selected == nil)
  }

  @Test("a live tab asks before closing")
  func liveTabConfirms() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1", live: true))
    let id = tabs.selected!
    tabs.requestClose(id)
    #expect(tabs.pendingClose == id)
    #expect(tabs.tabs.count == 1)
    tabs.confirmClose()
    #expect(tabs.tabs.isEmpty)
  }

  @Test("an ended tab asks too: the scrollback is still there")
  func endedTabConfirms() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1", live: false))
    let id = tabs.selected!
    tabs.requestClose(id)
    #expect(tabs.pendingClose == id)
    #expect(tabs.tabs.count == 1)
    tabs.confirmClose()
    #expect(tabs.tabs.isEmpty)
  }

  @Test("cancelling the question keeps the tab")
  func cancelledCloseKeepsTab() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.requestClose(tabs.selected!)
    tabs.pendingClose = nil
    #expect(tabs.tabs.count == 1)
  }

  @Test("an extension workspace asks before closing, and is named")
  func extensionConfirms() {
    let tabs = TabSet()
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

  @Test("the question names the terminal, and the verb is the button")
  func questionNamesTheTab() {
    let tabs = TabSet()
    #expect(tabs.closeQuestion == "Close?")
    tabs.adopt(tab(.local, name: "Terminal 2"))
    tabs.requestClose(tabs.selected!)
    #expect(tabs.closeQuestion == "Close Terminal 2?")
  }

  @Test("zen hides inspector and restores it")
  func zenPreservesInspector() {
    let tabs = TabSet()
    tabs.inspector = true
    tabs.toggleZen()
    #expect(tabs.zen)
    #expect(!tabs.inspector)
    tabs.toggleZen()
    #expect(!tabs.zen)
    #expect(tabs.inspector)
  }

  @Test("⌘W closes a selector before the tab")
  func closeSelectorFirst() {
    let tabs = TabSet()
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

  @Test("hiding the tab bar keeps sessions, selection and inspector, and dismisses anchored menus")
  func tabBarVisibilityPreservesWorkspace() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.adopt(tab(.local, name: "Terminal 2"))
    let selected = tabs.selected
    let ids = tabs.visibleIDs
    tabs.inspector = true
    tabs.tabMenu = selected
    tabs.accessory = AccessoryRef(tab: selected!, plugin: "test.tab")

    tabs.perform(.toggleTabBar)
    #expect(!tabs.showsTabBar)
    #expect(tabs.title(for: .toggleTabBar) == "Show Tab Bar")
    #expect(tabs.selected == selected)
    #expect(tabs.visibleIDs == ids)
    #expect(tabs.inspector)
    #expect(tabs.tabMenu == nil && tabs.accessory == nil)
    #expect(tabs.pendingClose == nil)

    tabs.perform(.previousTab)
    #expect(tabs.selected == ids.first)
    #expect(!tabs.showsTabBar)
    tabs.perform(.toggleTabBar)
    #expect(tabs.showsTabBar)
    #expect(tabs.title(for: .toggleTabBar) == "Hide Tab Bar")
    #expect(tabs.selected == ids.first)
  }

  #if os(macOS)
  @Test("zen preserves tab visibility, and Show Tab Bar exits zen")
  func tabBarVisibilityInZen() {
    let tabs = TabSet()
    tabs.perform(.toggleTabBar)
    tabs.perform(.zen)
    tabs.perform(.zen)
    #expect(!tabs.showsTabBar)
    tabs.inspector = true
    tabs.perform(.zen)
    tabs.perform(.toggleTabBar)
    #expect(!tabs.zen)
    #expect(tabs.showsTabBar)
    #expect(tabs.inspector)
  }

  @Test("opening an accessory reveals the hidden tab that anchors its popover")
  func accessoryRevealsTabBar() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    let id = tabs.selected!
    tabs.perform(.toggleTabBar)
    tabs.toggleAccessory("test.tab", on: id)
    #expect(tabs.showsTabBar)
    #expect(tabs.accessory == AccessoryRef(tab: id, plugin: "test.tab"))
    tabs.perform(.toggleTabBar)
    tabs.showAccessory("test.tab", on: id)
    #expect(tabs.showsTabBar)
    #expect(tabs.accessory == AccessoryRef(tab: id, plugin: "test.tab"))
  }
  #endif

  @Test("tabs are named as Terminal N per host")
  func namesAreLocal() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.adopt(tab(.local, name: "Terminal 2"))
    #expect(tabs.visibleTabs.map(\.name) == ["Terminal 1", "Terminal 2"])
  }

  @Test("what a plugin shows stands in for the shell, and names itself")
  func attachmentStandsInForShell() {
    let tabs = TabSet()
    let first = tab(.local, name: "Terminal 1")
    tabs.adopt(first)
    let attached = StubAttachment(subtitle: "dev / editor")
    first.attach(attached, for: "test.tab")
    #expect(first.shown == nil, "attached is not showing")
    #expect(first.subtitle.isEmpty)

    attached.isShowing = true
    #expect(first.shown === attached)
    #expect(first.subtitle == "dev / editor")
    #expect(tabs.workspaceCaption(for: .local) == "Local machine · Terminal 1 / dev / editor")
    #expect(tabs.statusLine().isEmpty)

    attached.isDisconnected = true
    #expect(tabs.statusLine() == "Disconnected")
  }

  @Test("a tab does not show the remote window title")
  func subtitleIgnoresRemoteTitle() {
    let first = tab(.local, name: "Terminal 1")
    #expect(first.subtitle.isEmpty)
  }

  @Test("closing a tab closes what plugins kept on it")
  func closingTabClosesAttachments() {
    let tabs = TabSet()
    let first = tab(.local, name: "Terminal 1")
    tabs.adopt(first)
    let attached = StubAttachment()
    first.attach(attached, for: "test.tab")
    tabs.close(first.id)
    #expect(attached.closed)
  }

  @Test("turning a plugin off takes it off every tab")
  func disablingDetaches() {
    let tabs = TabSet()
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

  @Test("turning a plugin off takes its sheet down too")
  func disablingDismissesSheet() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.sheet = PluginSheet(tab: tabs.selected!, plugin: "test.tab", view: AnyView(EmptyView()))
    tabs.closePlugin("test.other")
    #expect(tabs.sheet != nil)
    tabs.closePlugin("test.tab")
    #expect(tabs.sheet == nil)
  }

  @Test("a plugin's note is the one line under the close question")
  func closeNoteComesFromThePlugin() {
    let tabs = TabSet()
    let first = tab(.local, name: "Terminal 1")
    tabs.adopt(first)
    tabs.requestClose(first.id)
    #expect(tabs.closeNote == nil)
    first.attach(StubAttachment(closeNote: "Kept on the host."), for: "test.tab")
    #expect(tabs.closeNote == "Kept on the host.")
  }

  @Test("clicking the selected tab opens the first accessory")
  func selectedTabClickOpensAccessory() {
    let tabs = TabSet()
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

  @Test("clicking the selected tab opens the picker, and leaves the inspector alone")
  func selectedTabClickSkipsTheInspector() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    let id = tabs.selected!
    tabs.accessories = [
      PluginAccessory(
        id: "test.files", title: "Files",
        accessory: TabAccessory(symbol: "folder", name: "Files", placement: .inspector)),
      PluginAccessory(
        id: "test.tab", title: "Test", accessory: TabAccessory(symbol: "star", name: "things")),
    ]
    tabs.current?.attach(StubAttachment(), for: "test.files")
    tabs.current?.attach(StubAttachment(), for: "test.tab")
    tabs.handleTabClick(id)
    #expect(tabs.accessory == AccessoryRef(tab: id, plugin: "test.tab"))
    #expect(!tabs.inspector)

    tabs.accessory = nil
    tabs.accessories = [
      PluginAccessory(
        id: "test.files", title: "Files",
        accessory: TabAccessory(symbol: "folder", name: "Files", placement: .inspector))
    ]
    tabs.handleTabClick(id)
    #expect(tabs.accessory == nil)
    #expect(!tabs.inspector)
  }

  @Test("an accessory kept beside the terminal opens the inspector, not a popover")
  func inspectorAccessoryTogglesTheInspector() {
    let tabs = TabSet()
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
    let tabs = TabSet()
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
    @Test("opening an inspector accessory leaves zen, which hides the inspector")
    func inspectorAccessoryLeavesZen() {
      let tabs = TabSet()
      tabs.adopt(tab(.local, name: "Terminal 1"))
      tabs.accessories = [
        PluginAccessory(
          id: "test.files", title: "Files",
          accessory: TabAccessory(symbol: "folder", name: "Files", placement: .inspector))
      ]
      tabs.toggleZen()
      tabs.toggleAccessory("test.files", on: tabs.selected!)
      #expect(!tabs.zen)
      #expect(tabs.inspector)
    }

    @Test("turning a plugin off takes it out of the inspector")
    func disablingClearsTheInspector() {
      let tabs = TabSet()
      tabs.adopt(tab(.local, name: "Terminal 1"))
      tabs.accessories = [
        PluginAccessory(
          id: "test.files", title: "Files",
          accessory: TabAccessory(symbol: "folder", name: "Files", placement: .inspector))
      ]
      tabs.toggleAccessory("test.files", on: tabs.selected!)
      tabs.closePlugin("test.files")
      #expect(tabs.inspectorPlugin == nil)
    }
  #endif

  @Test("an ended tab is not a connection to reuse")
  func endedTabHasNoLease() async throws {
    let tabs = TabSet()
    let lab = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: nil)
    tabs.adopt(tab(lab, name: "Terminal 1", live: false))
    #expect(try await tabs.lease(for: lab) == nil)
  }

  @Test("a live preview tab has no lease until a session exists")
  func previewTabHasNoLease() async throws {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1", live: true))
    #expect(try await tabs.lease(for: .local) == nil, "stage is not the lease; the session is")
  }

  @Test("⌘W closes an open accessory before the tab")
  func closeAccessoryFirst() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    tabs.toggleAccessory("test.tab", on: tabs.selected!)
    tabs.requestCloseSelected()
    #expect(tabs.accessory == nil)
    #expect(tabs.tabs.count == 1)
  }

  @Test("a live shell does not caption itself connected")
  func liveShellHasNoStatusCaption() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1"))
    #expect(tabs.statusLine().isEmpty)
  }

  @Test("status names a problem, not a kind")
  func statusNamesAProblem() {
    let tabs = TabSet()
    tabs.adopt(tab(.local, name: "Terminal 1", live: false))
    #expect(tabs.statusLine() == "Ended")
  }

  @Test("no host is not a second caption next to Choose host")
  func noHostHasNoStatusCaption() {
    #expect(TabSet().statusLine().isEmpty)
  }

  @Test("an empty workspace says so once")
  func emptyWorkspaceStatus() {
    let tabs = TabSet()
    tabs.currentHost = .local
    #expect(tabs.statusLine() == "No open terminals")
  }

  @Test("host picker caption is a place, not a connection lecture")
  func hostCaptionIsPlace() {
    let tabs = TabSet()
    #expect(tabs.workspaceCaption(for: .local) == "Local machine")
    tabs.adopt(tab(.local, name: "Terminal 1"))
    #expect(tabs.workspaceCaption(for: .local) == "Local machine · Terminal 1")
  }
}
