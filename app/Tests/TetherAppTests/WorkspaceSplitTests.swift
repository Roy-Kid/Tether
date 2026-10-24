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

  @Test("four directions split the requested tab, including a background tab", arguments: SplitDirection.allCases)
  func splitRequestedTab(direction: SplitDirection) {
    let tabs = TabSet()
    let first = tab("first"), background = tab("background"), new = tab("new")
    tabs.adopt(first)
    tabs.adopt(background)
    tabs.select(first.id)
    tabs.split(new, beside: background.id, direction: direction)
    let expected: WorkspaceSplit
    switch direction {
    case .left, .up: expected = .split(direction, .tab(new.id), .tab(background.id), 0.5)
    case .right, .down: expected = .split(direction, .tab(background.id), .tab(new.id), 0.5)
    }
    #expect(tabs.workspaceSplit == expected)
    #expect(tabs.selected == new.id)
    #expect(tabs.tabs.count == 3)
  }

  @Test("all split commands target the selected terminal and respect available space")
  func directionalCommands() {
    let tabs = TabSet()
    let shell = tab("shell")
    let actions: [(WorkspaceAction, SplitDirection)] = [
      (.splitLeft, .left), (.splitRight, .right), (.splitUp, .up), (.splitDown, .down),
    ]
    tabs.adopt(shell)
    for (action, direction) in actions {
      #expect(WorkspaceAction.available.contains(action))
      #expect(tabs.canPerform(action))
      tabs.perform(action)
      #expect(tabs.intent == .splitTerminal(shell.id, direction))
      tabs.intent = nil
      tabs.wide = false
      #expect(!tabs.canPerform(action))
      tabs.perform(action)
      #expect(tabs.intent == nil)
      tabs.wide = true
    }
  }

  @Test("dragging a tab to another's side splits that pane and keeps the session")
  func dragTabBesideAnother() {
    let tabs = TabSet()
    let a = tab("a"), b = tab("b"), c = tab("c")
    tabs.adopt(a)
    tabs.adopt(b)
    tabs.adopt(c)
    #expect(tabs.place(b.id, beside: a.id, edge: .right))
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .tab(b.id), 0.5))
    #expect(tabs.selected == b.id)
    #expect(tabs.tabs.count == 3)
    #expect(tabs.place(c.id, beside: a.id, edge: .down))
    #expect(tabs.workspaceSplit == .split(.right, .split(.down, .tab(a.id), .tab(c.id), 0.5), .tab(b.id), 0.5))
    #expect(!tabs.place(a.id, beside: a.id, edge: .left))
    let other = tab("other", host: Host(label: "gpu", hostname: "gpu", port: 22, username: "me", keyPath: nil))
    tabs.adopt(other)
    #expect(!tabs.place(other.id, beside: a.id, edge: .left))
    #expect(SplitDirection.drop(x: 10, y: 8, width: 100, height: 28, band: nil) == .left)
    #expect(SplitDirection.drop(x: 80, y: 8, width: 100, height: 28, band: nil) == .right)
    #expect(SplitDirection.drop(x: 40, y: 10, width: 80, height: 200, band: nil) == .up)
    #expect(SplitDirection.drop(x: 100, y: 100, width: 200, height: 200, band: 0.28) == nil)
    #expect(SplitDirection.drop(x: 10, y: 100, width: 200, height: 200, band: 0.28) == .left)
  }

  @Test("left and up remain in visual order through nesting, persistence, remapping and close")
  func leadingSplits() throws {
    let tabs = TabSet()
    let a = tab("a"), b = tab("b"), c = tab("c")
    tabs.adopt(a)
    tabs.split(b, beside: a.id, direction: .left)
    tabs.split(c, beside: a.id, direction: .up)
    let expected: WorkspaceSplit = .split(.left, .tab(b.id), .split(.up, .tab(c.id), .tab(a.id), 0.5), 0.5)
    #expect(tabs.workspaceSplit == expected)
    #expect(tabs.selected == c.id)
    let decoded = try JSONDecoder().decode(WorkspaceSplit.self, from: JSONEncoder().encode(expected))
    #expect(decoded == expected)
    let x = UUID(), y = UUID(), z = UUID()
    #expect(decoded.remapping([a.id: x, b.id: y, c.id: z]) ==
      .split(.left, .tab(y), .split(.up, .tab(z), .tab(x), 0.5), 0.5))
    tabs.close(a.id, remember: false)
    #expect(tabs.workspaceSplit == .split(.left, .tab(b.id), .tab(c.id), 0.5))
    #expect(tabs.selected == c.id)
    tabs.close(c.id, remember: false)
    #expect(tabs.workspaceSplit == nil)
    #expect(tabs.selected == b.id)
  }

  #if os(macOS)
  @Test("terminal context splits target a background pane in every direction")
  func contextDirections() {
    let tabs = TabSet()
    let a = tab("a"), b = tab("b")
    tabs.adopt(a)
    tabs.adopt(b)
    for (title, direction): (String, SplitDirection) in [
      ("Split Left", .left), ("Split Right", .right), ("Split Up", .up), ("Split Down", .down),
    ] {
      tabs.select(b.id)
      let item = tabs.terminalMenu(for: a.id).first { $0.title == title }
      #expect(item != nil)
      item?.action?()
      #expect(tabs.current?.id == a.id)
      #expect(tabs.intent == .splitTerminal(a.id, direction))
      tabs.intent = nil
    }
  }
  #endif

  @Test("nested splits collapse on close and preserve the surviving pane")
  func closePane() {
    let tabs = TabSet()
    let a = tab("a"), b = tab("b"), c = tab("c")
    tabs.adopt(a)
    tabs.split(b, beside: a.id, direction: .right)
    tabs.split(c, beside: b.id, direction: .down)
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .split(.down, .tab(b.id), .tab(c.id), 0.5), 0.5))
    tabs.close(c.id, remember: false)
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .tab(b.id), 0.5))
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
    #expect(tabs.workspaceSplit == .split(.right, .tab(hidden.id), .tab(b.id), 0.5))
    tabs.adopt(new, in: tabs.currentWorkspace!.id)
    #expect(tabs.workspaceSplit == .split(.right, .tab(new.id), .tab(b.id), 0.5))
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
    #expect(tabs.workspaceSplit == .split(.right, .tab(a.id), .tab(b.id), 0.5))
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

  @Test("a dragged fraction is restored with the host")
  func fractionFollowsHost() throws {
    let tabs = TabSet()
    let remote = Host(label: "remote", hostname: "example.invalid", port: 22, username: "test")
    let a = tab("a"), b = tab("b"), c = tab("c", host: remote)
    tabs.adopt(a)
    tabs.split(b, beside: a.id, direction: .right)
    let page = try #require(tabs.currentWorkspace?.id)
    let resized = try #require(tabs.workspaceSplit).withFraction(0.3)
    tabs.replaceLayout(of: page, with: resized)
    tabs.adopt(c)
    #expect(tabs.workspaceSplit == nil)
    tabs.show(.local)
    #expect(tabs.workspaceSplit == resized)
    #expect(tabs.selected == b.id)
    #expect(tabs.currentHost?.id == Host.local.id)
  }

  @Test("a saved split without a fraction opens at half")
  func legacyFraction() throws {
    let first = UUID(), second = UUID()
    let legacy = """
    {"split":{"_0":"down","_1":{"tab":{"_0":"\(first.uuidString)"}},"_2":{"tab":{"_0":"\(second.uuidString)"}}}}
    """
    let decoded = try JSONDecoder().decode(WorkspaceSplit.self, from: Data(legacy.utf8))
    #expect(decoded == .split(.down, .tab(first), .tab(second), 0.5))
    let kept = """
    {"split":{"_0":"down","_1":{"tab":{"_0":"\(first.uuidString)"}},"_2":{"tab":{"_0":"\(second.uuidString)"}},"_3":0.3}}
    """
    let uneven = try JSONDecoder().decode(WorkspaceSplit.self, from: Data(kept.utf8))
    #expect(uneven == .split(.down, .tab(first), .tab(second), 0.3))
    let again = try JSONDecoder().decode(WorkspaceSplit.self, from: JSONEncoder().encode(uneven))
    #expect(again == uneven)
  }
}
