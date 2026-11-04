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
  #endif

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
