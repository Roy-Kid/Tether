import Foundation
import Testing
@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Native workspace splits")
struct WorkspaceSplitTests {
  private func tab(_ name: String, host: Host = .local) -> SessionTab {
    SessionTab(preview: host, known: KnownHosts(location: URL(fileURLWithPath: "/dev/null")), name: name, live: false)
  }

  @Test("split commands are the selected terminal, and join waits for a split")
  func splitCommands() {
    let tabs = TabSet()
    #expect(!tabs.canPerform(.splitRight))
    #expect(!tabs.canPerform(.splitDown))
    #expect(!tabs.canPerform(.joinGroups))
    let shell = tab("shell")
    tabs.adopt(shell)
    #expect(tabs.canPerform(.splitRight))
    #expect(tabs.canPerform(.splitDown))
    tabs.perform(.splitRight)
    #expect(tabs.intent == .splitTerminal(shell.id, .right))
    tabs.intent = nil
    tabs.perform(.splitDown)
    #expect(tabs.intent == .splitTerminal(shell.id, .down))
    tabs.perform(.joinGroups)
    #expect(tabs.workspaceSplit == nil)
    #if os(macOS)
      #expect(WorkspaceAction.available.contains(.splitRight))
      #expect(WorkspaceAction.splitRight.command.title == "Split Right")
      #expect(WorkspaceAction.splitDown.command.group == "Terminal")
    #else
      // Offered everywhere; a window without room says no (see TouchWorkspaceTests).
      #expect(WorkspaceAction.available.contains(.splitRight))
    #endif
  }

  @Test("right and down split the requested tab, including a background tab", arguments: SplitDirection.allCases)
  func splitRequestedTab(direction: SplitDirection) {
    let tabs = TabSet()
    let first = tab("first"), background = tab("background"), new = tab("new")
    tabs.adopt(first)
    tabs.adopt(background)
    tabs.select(first.id)
    tabs.split(new, beside: background.id, direction: direction)
    #expect(tabs.workspaceSplit == .split(direction, .tab(background.id), .tab(new.id)))
    #expect(tabs.selected == new.id)
    #expect(tabs.tabs.count == 3)
  }

  @Test("nested splits collapse on close and preserve the surviving pane")
  func closePane() {
    let tabs = TabSet()
    let a = tab("a"), b = tab("b"), c = tab("c")
    tabs.adopt(a)
    tabs.split(b, beside: a.id, direction: .right)
    tabs.split(c, beside: b.id, direction: .down)
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .split(.down, .tab(b.id), .tab(c.id))))
    tabs.close(c.id, remember: false)
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .tab(b.id)))
    #expect(tabs.current != nil)
    tabs.close(a.id, remember: false)
    #expect(tabs.workspaceSplit == nil)
    #expect(tabs.current?.id == b.id)
  }

  @Test("tab selection changes only the focused pane; joining keeps sessions")
  func selectionAndJoin() {
    let tabs = TabSet()
    let a = tab("a"), b = tab("b"), hidden = tab("hidden"), new = tab("new")
    tabs.adopt(a)
    tabs.adopt(hidden, in: tabs.currentWorkspace!.id)
    tabs.select(a.id)
    tabs.split(b, beside: a.id, direction: .right)
    tabs.select(a.id)
    tabs.select(hidden.id)
    #expect(tabs.workspaceSplit == .split(.right, .tab(hidden.id), .tab(b.id)))
    tabs.adopt(new, in: tabs.currentWorkspace!.id)
    #expect(tabs.workspaceSplit == .split(.right, .tab(new.id), .tab(b.id)))
    tabs.joinSplits()
    #expect(tabs.workspaceSplit == nil)
    #expect(tabs.tabs.count == 4)
    #expect(tabs.current?.id == new.id)
  }

  @Test("layouts belong to their host and closing all clears them")
  func hostIsolation() {
    let tabs = TabSet()
    let remote = Host(label: "remote", hostname: "example.invalid", port: 22, username: "test")
    let a = tab("a"), b = tab("b"), c = tab("c", host: remote)
    tabs.adopt(a)
    tabs.split(b, beside: a.id, direction: .right)
    tabs.adopt(c)
    #expect(tabs.workspaceSplit == nil)
    tabs.show(.local)
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .tab(b.id)))
    #expect(tabs.selected == b.id)
    tabs.show(remote)
    tabs.close(b.id, remember: false)
    tabs.show(.local)
    #expect(tabs.workspaceSplit == nil)
    #expect(tabs.current?.id == a.id)
    tabs.closeAll()
    tabs.adopt(tab("fresh"))
    #expect(tabs.workspaceSplit == nil)
  }
}
