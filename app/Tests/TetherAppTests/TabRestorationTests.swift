import Foundation
import Testing
import Tether

@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Restoring closed tabs")
struct TabRestorationTests {
  private func tab(_ name: String, host: Host = .local) -> SessionTab {
    SessionTab(preview: host, known: KnownHosts(), name: name, live: false)
  }

  private func takeRequest(_ tabs: TabSet) throws -> ClosedTerminal {
    tabs.perform(.restoreTab)
    let id = try #require(tabs.restoringTab)
    #expect(tabs.intent == .restoreTab(id))
    tabs.intent = nil // The window consumes its intent before handling authentication.
    return try #require(tabs.restoration(for: id))
  }

  @Test("successive restores reopen newest first at the original positions and select them")
  func orderAndPosition() throws {
    let tabs = TabSet()
    let a = tab("A"), b = tab("Renamed B"), c = tab("C")
    [a, b, c].forEach { tabs.adopt($0) }
    tabs.requestClose(b.id)
    tabs.requestClose(a.id)
    #expect(tabs.closedTabs.map(\.name) == ["Renamed B", "A"])

    let first = try takeRequest(tabs)
    let restoredA = tab(first.name)
    #expect(tabs.completeRestore(first.id, with: restoredA))
    #expect(tabs.tabs.map(\.name) == ["A", "C"])
    #expect(tabs.selected == restoredA.id)
    let second = try takeRequest(tabs)
    let restoredB = tab(second.name)
    #expect(tabs.completeRestore(second.id, with: restoredB))
    #expect(tabs.tabs.map(\.name) == ["A", "Renamed B", "C"])
    #expect(tabs.selected == restoredB.id)
    #expect(!tabs.canPerform(.restoreTab))
    #expect(restoredB.id != b.id, "a reopened tab has a fresh session identity")
  }

  @Test("restoring returns to the original host even when another host is selected")
  func originalHost() throws {
    let remote = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: nil)
    let tabs = TabSet()
    let closed = tab("Remote work", host: remote)
    tabs.adopt(closed)
    tabs.close(closed.id)
    tabs.adopt(tab("Local"))
    let record = try takeRequest(tabs)
    #expect(record.host == remote)
    let restored = tab(record.name, host: record.host)
    #expect(tabs.completeRestore(record.id, with: restored))
    #expect(tabs.currentHost == remote)
    #expect(tabs.current?.id == restored.id)
  }

  @Test("authentication cancellation preserves history and duplicate requests do not consume it")
  func cancelledRestore() throws {
    let tabs = TabSet()
    let closed = tab("A")
    tabs.adopt(closed)
    tabs.close(closed.id)
    let record = try takeRequest(tabs)
    tabs.perform(.restoreTab)
    #expect(tabs.intent == nil)
    #expect(tabs.closedTabs.count == 1)
    tabs.cancelRestore(record.id)
    #expect(tabs.canPerform(.restoreTab))
    #expect(try takeRequest(tabs) == record)
  }

  @Test("a stale account cannot complete a restore or leave subsequent restores blocked")
  func staleAccount() throws {
    let tabs = TabSet()
    let closed = tab("A")
    tabs.adopt(closed)
    tabs.close(closed.id)
    let record = try takeRequest(tabs)
    var changed = record.host
    changed.accountScope = "another-account"
    #expect(!tabs.completeRestore(record.id, with: tab("A", host: changed)))
    #expect(tabs.tabs.isEmpty)
    #expect(tabs.restoringTab == nil)
    #expect(tabs.canRestoreTab)
  }

  @Test("cancelled closes, automatic invalidations and shutdown cannot populate restore history")
  func automaticClose() {
    let tabs = TabSet()
    let closed = tab("A")
    tabs.adopt(closed)
    tabs.pendingClose = closed.id
    tabs.pendingClose = nil
    #expect(tabs.closedTabs.isEmpty)
    tabs.close(closed.id, remember: false)
    #expect(tabs.closedTabs.isEmpty)
    let next = tab("B")
    tabs.adopt(next)
    tabs.close(next.id)
    tabs.perform(.restoreTab)
    tabs.closeAll()
    #expect(tabs.closedTabs.isEmpty)
    #expect(tabs.restoringTab == nil)
    #expect(tabs.intent == nil)
    #expect(tabs.restore(next.id, host: .local, password: "") == nil)
  }

  @Test("only the most recent twenty tabs are retained")
  func boundedHistory() {
    let tabs = TabSet()
    for index in 0..<25 {
      let closed = tab("\(index)")
      tabs.adopt(closed)
      tabs.close(closed.id)
    }
    #expect(tabs.closedTabs.count == TabSet.closedTabLimit)
    #expect(tabs.closedTabs.first?.name == "5")
    #expect(tabs.closedTabs.last?.name == "24")
  }

  @Test("deleted managed hosts cannot be restored, and label changes keep history")
  func changedHosts() throws {
    let profile = IdentityTests().profile()
    let host = Host(id: profile.id, label: profile.label, hostname: profile.hostname,
      port: profile.port, username: profile.username, profile: profile)
    let tabs = TabSet()
    let closed = tab("Remote", host: host)
    tabs.adopt(closed)
    tabs.close(closed.id)
    var renamed = host
    renamed.label = "Renamed host"
    renamed.profile?.label = renamed.label
    tabs.reconcileClosedTabs(with: [renamed])
    #expect(tabs.canRestoreTab)
    let record = try takeRequest(tabs)
    tabs.reconcileClosedTabs(with: [])
    #expect(tabs.closedTabs.isEmpty)
    #expect(tabs.restoringTab == nil)
    #expect(tabs.restore(record.id, host: host, password: "") == nil)
  }

  @Test("plugin metadata is saved before attachments are closed")
  func pluginState() {
    let tabs = TabSet()
    let closed = tab("A")
    let attachment = StubAttachment()
    attachment.restorationState = Data("saved-directory".utf8)
    closed.attach(attachment, for: "test.files")
    tabs.adopt(closed)
    tabs.close(closed.id)
    #expect(attachment.closed)
    #expect(tabs.closedTabs.last?.attachments == [
      ClosedTerminal.Attachment(pluginID: "test.files", state: Data("saved-directory".utf8))
    ])
  }

  @Test("a real local shell reopens in its previous directory with its previous name",
    .enabled(if: TerminalSession.isLocalAvailable))
  func localDirectory() async throws {
    let location = temporaryFile("placeholder").deletingLastPathComponent().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: location) }
    let canonical = try #require(realpath(location.path, nil))
    defer { free(canonical) }
    let directory = String(cString: canonical)
    let tabs = TabSet()
    defer { tabs.closeAll() }
    let original = SessionTab(host: .local, password: "", known: tabs.known,
      name: "Project shell", directory: location.path)
    tabs.adopt(original)
    _ = try await original.connectionReady()
    #expect(original.workingDirectory == directory)
    tabs.close(original.id)
    let record = try takeRequest(tabs)
    #expect(record.directory == directory)
    let restored = try #require(tabs.restore(record.id, host: .local, password: ""))
    _ = try await restored.connectionReady()
    #expect(restored.name == "Project shell")
    #expect(restored.workingDirectory == directory)
    #expect(restored.isLive)
  }
}
