import Foundation
import Testing
import Tether
@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Persistent session history")
struct SessionHistoryTests {
  private func tab(_ name: String) -> SessionTab {
    SessionTab(preview: .local, known: KnownHosts(), name: name, live: false)
  }

  @Test("closed metadata and open sessions survive a new store instance")
  func restart() throws {
    let directory = temporaryFile("history")
    defer { removeDirectory(of: directory) }
    let first = TabSet(historyStore: SessionHistoryStore(directory: directory))
    let closed = tab("Closed"), open = tab("Open")
    first.adopt(closed)
    first.close(closed.id)
    first.adopt(open)
    open.name = "Renamed open"
    first.shutdown()

    let second = TabSet(historyStore: SessionHistoryStore(directory: directory))
    #expect(second.closedTabs.map(\.name) == ["Closed", "Renamed open"])
    #expect(second.closedTabs.allSatisfy { $0.historyID != nil })
    #expect(second.tabs.isEmpty)
    second.requestRestoreTab()
    let id = try #require(second.restoringTab)
    let record = try #require(second.restoration(for: id))
    let restored = tab(record.name)
    #expect(second.completeRestore(id, with: restored))
    #expect(restored.historyID == open.historyID)
    #expect(second.closedTabs.map(\.name) == ["Closed"])
    #expect(second.historyProblem == nil)
  }

  @Test("security/account reset removes metadata and archived contents")
  func reset() throws {
    let directory = temporaryFile("history")
    defer { removeDirectory(of: directory) }
    let store = SessionHistoryStore(directory: directory)
    let tabs = TabSet(historyStore: store)
    let item = tab("A")
    tabs.adopt(item)
    let id = try #require(item.historyID)
    tabs.close(item.id)
    tabs.closeAll()
    #expect(SessionHistoryStore(directory: directory).load().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.location(id).path))
  }

  @Test("a corrupt manifest is reported and never overwrites or deletes archives")
  func corruptManifest() throws {
    let directory = temporaryFile("history")
    defer { removeDirectory(of: directory) }
    let store = SessionHistoryStore(directory: directory)
    let archive = store.location(UUID())
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let original = Data("broken manifest".utf8)
    let manifest = directory.appending(path: "tabs.json")
    try original.write(to: manifest)
    let tabs = TabSet(historyStore: SessionHistoryStore(directory: directory))
    tabs.adopt(tab("New"))
    tabs.persistHistory()
    #expect(tabs.historyProblem != nil)
    #expect(try Data(contentsOf: manifest) == original)
    #expect(FileManager.default.fileExists(atPath: archive.path))
  }

  @Test("a save does not delete an archive the manifest has not recorded yet")
  func saveKeepsUnrecordedArchive() throws {
    let directory = temporaryFile("history")
    defer { removeDirectory(of: directory) }
    let store = SessionHistoryStore(directory: directory)
    let recordedTab = tab("Recorded")
    let recordedID = UUID()
    recordedTab.historyID = recordedID
    try FileManager.default.createDirectory(at: store.location(recordedID), withIntermediateDirectories: true)
    store.save(open: [ClosedTerminal(recordedTab, index: 0)], closed: [])
    let fresh = UUID()
    try FileManager.default.createDirectory(at: store.location(fresh), withIntermediateDirectories: true)
    recordedTab.name = "Renamed"
    store.save(open: [ClosedTerminal(recordedTab, index: 0)], closed: [])
    #expect(FileManager.default.fileExists(atPath: store.location(fresh).path))
    #expect(FileManager.default.fileExists(atPath: store.location(recordedID).path))
  }

  @Test("an archive left behind by a crash is removed when the manifest is loaded")
  func loadRemovesOrphan() throws {
    let directory = temporaryFile("history")
    defer { removeDirectory(of: directory) }
    let store = SessionHistoryStore(directory: directory)
    let kept = tab("Kept")
    kept.historyID = UUID()
    try FileManager.default.createDirectory(at: store.location(kept.historyID!), withIntermediateDirectories: true)
    store.save(open: [ClosedTerminal(kept, index: 0)], closed: [])
    let orphan = UUID()
    try FileManager.default.createDirectory(at: store.location(orphan), withIntermediateDirectories: true)
    let reloaded = SessionHistoryStore(directory: directory)
    _ = reloaded.load()
    #expect(!FileManager.default.fileExists(atPath: store.location(orphan).path))
    #expect(FileManager.default.fileExists(atPath: store.location(kept.historyID!).path))
  }

  @Test("opening a terminal while the snapshot is dirty keeps the new archive")
  func newTerminalKeepsArchive() throws {
    let directory = temporaryFile("history")
    defer { removeDirectory(of: directory) }
    let store = SessionHistoryStore(directory: directory)
    let tabs = TabSet(historyStore: store)
    let first = tab("First")
    tabs.adopt(first)
    tabs.workspaces[0].name = "Changed"
    let second = tab("Second")
    tabs.adopt(second)
    let id = try #require(second.historyID)
    #expect(FileManager.default.fileExists(atPath: store.location(id).path))
    #expect(tabs.historyProblem == nil)
  }

  @Test("an account change does not delete the local shell's open archive")
  func accountChangeKeepsLocalArchive() throws {
    let directory = temporaryFile("history")
    defer { removeDirectory(of: directory) }
    let store = SessionHistoryStore(directory: directory)
    let tabs = TabSet(historyStore: store, inspectActivity: { _ in .idle })
    let local = tab("local")
    let remoteHost = Host(label: "lab", hostname: "lab.invalid", port: 22, username: "ada")
    let remote = SessionTab(preview: remoteHost, known: KnownHosts(), name: "lab", live: false)
    tabs.adopt(local)
    tabs.adopt(remote)
    let localID = try #require(local.historyID)
    let remoteID = try #require(remote.historyID)
    tabs.closeAccountSessions()
    #expect(FileManager.default.fileExists(atPath: store.location(localID).path))
    #expect(!FileManager.default.fileExists(atPath: store.location(remoteID).path))
    #expect(tabs.tabs.map(\.id) == [local.id])
  }

}
