import Foundation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import TetherApp

@Suite("Native terminal layouts")
struct TerminalLayoutTests {
  @Test("recursive splits preserve unrelated leaves and collapse empty branches")
  func tree() throws {
    let a = UUID(), b = UUID(), c = UUID()
    let layout = TerminalLayout.pane(a).splitting(a, adding: b, vertical: false)
      .splitting(b, adding: c, vertical: true)
    #expect(layout.leaves == [a, b, c])
    #expect(layout.minimumSize == CGSize(width: 321, height: 201))
    #expect(layout.isValid(panes: [a, b, c]))
    #expect(!layout.isValid(panes: [a, b]))
    #expect(!TerminalLayout.split(vertical: false, ratio: .nan, first: .pane(a), second: .pane(b)).isValid(panes: [a, b]))
    #expect(!TerminalLayout.split(vertical: false, ratio: 0.5, first: .pane(a), second: .pane(a)).isValid(panes: [a]))
    #expect(layout.removing(b)?.leaves == [a, c])
    #expect(layout.removing(a)?.leaves == [b, c])
    #expect(layout.removing(a)?.restoring(a, beside: [b, c], vertical: false, before: true, ratio: 0.5) == layout)
    #expect(layout.removing(a)?.removing(b) == .pane(c))
    #expect(layout.removing(a)?.removing(b)?.removing(c) == nil)
    #expect(layout.neighbor(of: b)?.0 == c)
    #expect(layout.neighbor(of: b)?.1 == true)
    let decoded = try JSONDecoder().decode(TerminalLayout.self, from: JSONEncoder().encode(layout))
    #expect(decoded == layout)
    let replacement = UUID()
    #expect(layout.remapping([b: replacement]).leaves == [a, replacement, c])
  }

  @MainActor @Test("pane focus, maximize and close keep the other sessions owned")
  func ownership() throws {
    let set = TabSet()
    let a = SessionTab(preview: .local, known: KnownHosts(), name: "A", live: false)
    let b = SessionTab(preview: .local, known: KnownHosts(), name: "B", live: false)
    let c = SessionTab(preview: .local, known: KnownHosts(), name: "C", live: false)
    set.adopt(a)
    set.pendingSplit = (a.id, false)
    set.adopt(b)
    set.pendingSplit = (b.id, true)
    set.adopt(c)
    #expect(set.visibleTabs.count == 1)
    #expect(set.current?.id == c.id)
    let workspace = try #require(set.currentWorkspace)
    workspace.maximized = true
    #expect(set.tabs.count == 3)
    #expect(set.visiblePaneIDs == [c.id])
    set.focusPane(b.id)
    #expect(set.current?.id == b.id)
    set.close(b.id)
    #expect(workspace.layout.leaves == [a.id, c.id])
    #expect(!workspace.maximized)
    #expect(set.visiblePaneIDs == [a.id, c.id])
    #expect(set.closedTabs.last?.parentID == workspace.id)
    set.close(a.id)
    #expect(set.visibleTabs.count == 1)
    #expect(set.current?.id == c.id)
    c.onHistoryChanged?()
    #expect(workspace.name == "A")
    set.close(c.id)
    #expect(set.tabs.isEmpty)
  }

  #if os(macOS)
  @MainActor @Test("AppKit divider dragging and maximization retain terminal view instances")
  func nativeViews() throws {
    _ = NSApplication.shared
    let set = TabSet()
    let a = SessionTab(preview: .local, known: KnownHosts(), name: "A", live: false)
    let b = SessionTab(preview: .local, known: KnownHosts(), name: "B", live: false)
    set.adopt(a); set.pendingSplit = (a.id, false); set.adopt(b)
    let workspace = try #require(set.currentWorkspace)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
    window.contentView = root
    defer { window.contentView = nil; window.close(); set.closeAll() }
    let coordinator = TerminalWorkspaceView.Coordinator()
    coordinator.update(root, workspace: workspace, tabs: set) { _ in AnyView(Color.clear) }
    root.layoutSubtreeIfNeeded()
    let split = try #require(root.subviews.first as? NSSplitView)
    let first = try #require(coordinator.hosts[a.id])
    let second = try #require(coordinator.hosts[b.id])
    split.setPosition(200, ofDividerAt: 0)
    coordinator.update(root, workspace: workspace, tabs: set) { _ in AnyView(Color.clear) }
    #expect(root.subviews.first === split)
    let ratio = try #require((split as? TerminalWorkspaceView.ProportionalSplit)?.initialRatio)
    root.setFrameSize(NSSize(width: 240, height: 180))
    root.layoutSubtreeIfNeeded()
    #expect(abs(first.frame.width / (split.bounds.width - split.dividerThickness) - ratio) < 0.001)
    root.setFrameSize(NSSize(width: 640, height: 480))
    root.layoutSubtreeIfNeeded()
    #expect(abs(first.frame.width / (split.bounds.width - split.dividerThickness) - ratio) < 0.001)
    #expect(coordinator.hosts[a.id] === first)
    #expect(coordinator.hosts[b.id] === second)
    workspace.maximized = true
    coordinator.update(root, workspace: workspace, tabs: set) { _ in AnyView(Color.clear) }
    #expect(root.subviews.first === second)
    #expect(set.tabs.count == 2)
    workspace.maximized = false
    coordinator.update(root, workspace: workspace, tabs: set) { _ in AnyView(Color.clear) }
    root.layoutSubtreeIfNeeded()
    #expect(coordinator.hosts[a.id] === first)
    #expect(coordinator.hosts[b.id] === second)
    #expect(root.subviews.first is NSSplitView)
  }

  @MainActor @Test("restoring a closed root pane preserves its side and stable workspace identity")
  func restorePanePosition() throws {
    let set = TabSet()
    func pane(_ name: String) -> SessionTab { SessionTab(preview: .local, known: KnownHosts(), name: name, live: false) }
    let a = pane("A"), b = pane("B"), c = pane("C")
    set.adopt(a)
    set.pendingSplit = (a.id, false); set.adopt(b)
    set.pendingSplit = (b.id, true); set.adopt(c)
    let workspace = try #require(set.currentWorkspace)
    let id = workspace.id
    set.close(a.id)
    set.requestRestoreTab()
    let record = try #require(set.restoration(for: try #require(set.restoringTab)))
    let reopened = pane("A")
    #expect(set.commitRestoration(record, panes: [reopened]))
    #expect(set.currentWorkspace?.id == id)
    #expect(set.currentWorkspace?.layout.leaves == [reopened.id, b.id, c.id])
    #expect(set.visibleTabs.count == 1)
    set.closeWorkspace(try #require(set.selected))
    set.requestRestoreTab()
    let entire = try #require(set.restoration(for: try #require(set.restoringTab)))
    let replacement = [pane("A"), pane("B"), pane("C")]
    #expect(set.commitRestoration(entire, panes: replacement))
    #expect(set.currentWorkspace?.id == id)
    #expect(set.visibleTabs.count == 1)
    #expect(set.currentWorkspace?.layout.leaves.count == 3)
    set.closeAll()
  }
  #endif

  @MainActor @Test("directional focus chooses the nearest visible pane and stays put at an edge")
  func directionalFocus() throws {
    let set = TabSet()
    let a = SessionTab(preview: .local, known: KnownHosts(), name: "A", live: false)
    let b = SessionTab(preview: .local, known: KnownHosts(), name: "B", live: false)
    let c = SessionTab(preview: .local, known: KnownHosts(), name: "C", live: false)
    set.adopt(a); set.pendingSplit = (a.id, false); set.adopt(b)
    set.pendingSplit = (b.id, true); set.adopt(c)
    let workspace = try #require(set.currentWorkspace)
    workspace.paneFrames = [a.id: CGRect(x: 0, y: 0, width: 160, height: 100),
      b.id: CGRect(x: 200, y: 0, width: 160, height: 100), c.id: CGRect(x: 200, y: 200, width: 160, height: 100)]
    set.focusPane(a.id)
    set.movePaneFocus(dx: 1, dy: 0)
    #expect(set.current?.id == b.id)
    set.movePaneFocus(dx: 0, dy: -1)
    #expect(set.current?.id == c.id)
    set.movePaneFocus(dx: 1, dy: 0)
    #expect(set.current?.id == c.id)
    workspace.maximized = true
    set.movePaneFocus(dx: -1, dy: 0)
    #expect(set.current?.id == c.id)
    set.closeAll()
  }

  @MainActor @Test("all pane histories survive restart without reconnecting")
  func persistence() throws {
    let directory = temporaryFile("split-history")
    defer { removeDirectory(of: directory) }
    let set = TabSet(historyStore: SessionHistoryStore(directory: directory))
    let a = SessionTab(preview: .local, known: KnownHosts(), name: "A", live: false)
    let b = SessionTab(preview: .local, known: KnownHosts(), name: "B", live: false)
    set.adopt(a)
    set.pendingSplit = (a.id, false)
    set.adopt(b)
    set.checkpointHistory()
    let reopened = TabSet(historyStore: SessionHistoryStore(directory: directory))
    let record = try #require(reopened.closedTabs.last)
    #expect(record.layout?.leaves == [a.id, b.id])
    #expect(record.panes?.count == 2)
    #expect(record.focusedPane == b.id)
    #expect(reopened.tabs.isEmpty)
    for id in [a.historyID, b.historyID].compactMap({ $0 }) {
      #expect(FileManager.default.fileExists(atPath: directory.appending(path: id.uuidString).path))
    }
    set.closeAll()
  }
}
