import Foundation
import Testing

@testable import TetherApp

@MainActor
@Suite("Closing a terminal with running work")
struct TabCloseTests {
  private func tab(live: Bool = true) -> SessionTab {
    SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: live)
  }

  private func settle(_ tabs: TabSet) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while tabs.checkingClose != nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(tabs.checkingClose == nil)
  }

  @Test("an idle live terminal closes immediately after checking")
  func idle() async throws {
    let tabs = TabSet(inspectActivity: { _ in .idle })
    tabs.adopt(tab())
    var emptied = 0
    tabs.onEmptied = { emptied += 1 }
    tabs.requestCloseSelected()
    try await settle(tabs)
    #expect(tabs.tabs.isEmpty)
    #expect(tabs.pendingClose == nil)
    #expect(emptied == 1)
  }

  @Test("running work is named; cancellation preserves it and confirmation closes it")
  func running() async throws {
    let tabs = TabSet(inspectActivity: { _ in .running(["sleep", "vim"]) })
    tabs.adopt(tab())
    let id = tabs.selected!
    tabs.requestClose(id)
    try await settle(tabs)
    #expect(tabs.pendingClose == id)
    #expect(tabs.closeNote?.contains("sleep, vim") == true)
    #expect(tabs.closeNote?.contains("lose unsaved work") == true)
    #expect(tabs.tabs.count == 1)
    tabs.pendingClose = nil
    #expect(tabs.tabs.count == 1)
    tabs.requestClose(id)
    try await settle(tabs)
    tabs.confirmClose()
    #expect(tabs.tabs.isEmpty)
  }

  @Test("active transfers ask even after the shell ends; a detached session note alone does not")
  func pluginWork() {
    let tabs = TabSet()
    let terminal = tab(live: false)
    let attachment = StubAttachment(closeNote: "1 transfer stops.")
    attachment.requiresCloseConfirmation = true
    terminal.attach(attachment, for: "test.files")
    tabs.adopt(terminal)
    tabs.requestClose(terminal.id)
    #expect(tabs.pendingClose == terminal.id)
    #expect(tabs.closeNote == "1 transfer stops.")
    tabs.pendingClose = nil
    attachment.requiresCloseConfirmation = false
    attachment.closeNote = "tmux stays on the host."
    tabs.requestClose(terminal.id)
    #expect(tabs.tabs.isEmpty)
    #expect(attachment.closed)
  }

  @Test("repeat close gestures share one check, and changing selection cannot close the new tab")
  func repeatAndSelection() async throws {
    var checks = 0
    var answer: CheckedContinuation<ShellActivity, Never>?
    let tabs = TabSet(inspectActivity: { _ in
      checks += 1
      return await withCheckedContinuation { answer = $0 }
    })
    let first = tab()
    let second = tab()
    tabs.adopt(first)
    tabs.adopt(second)
    tabs.requestClose(first.id)
    tabs.requestClose(first.id)
    while answer == nil { await Task.yield() }
    tabs.select(second.id)
    answer?.resume(returning: .idle)
    try await settle(tabs)
    #expect(checks == 1)
    #expect(tabs.tabs.map(\.id) == [second.id])
    #expect(tabs.selected == second.id)
  }

  @Test("a result arriving after the tab closes cannot present a stale dialog")
  func staleResult() async throws {
    var answer: CheckedContinuation<ShellActivity, Never>?
    let tabs = TabSet(inspectActivity: { _ in
      await withCheckedContinuation { answer = $0 }
    })
    let terminal = tab()
    tabs.adopt(terminal)
    tabs.requestClose(terminal.id)
    while answer == nil { await Task.yield() }
    tabs.closeAll()
    answer?.resume(returning: .running(["sleep"]))
    // Let the suspended check reach its cancellation guard.
    try await Task.sleep(for: .milliseconds(20))
    #expect(tabs.pendingClose == nil)
    #expect(tabs.checkingClose == nil)
    #expect(tabs.tabs.isEmpty)
  }
}
