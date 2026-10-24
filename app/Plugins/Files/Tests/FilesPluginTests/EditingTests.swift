import Foundation
import Testing
import Tether
import TetherPluginKit

@testable import FilesPlugin

/// A file opened to be edited: a copy here, written back each time it is
/// saved, and gone once its editor is.
@MainActor
@Suite("editing a remote file", .serialized)
struct EditingTests {
  static let notes = "/home/ada/notes.txt"
  private let tree: [String: FileKind] = [
    "/": .directory, "/home": .directory, "/home/ada": .directory,
    notes: .file, "/home/ada/run.sh": .file,
  ]

  private final class Opened { var urls: [URL] = [] }

  private func context() -> TabContext {
    TabContext(
      id: UUID(),
      plugin: PluginContext(
        connection: nil, hostLabel: "lab", hostID: UUID(),
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
  }

  private func tab(_ source: StubSource, editing: EditingCopies? = nil, opened: Opened = Opened()) -> FilesTab {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("editing-\(UUID())")
    let model = FilesTab(
      tab: context(), cache: FileCache(host: UUID(), base: base), editing: editing ?? scratchEditing(),
      open: { _ in source }, present: { _ in }, defaults: cleanDefaults())
    model.openLocal = { opened.urls.append($0) }
    model.openToEdit = { url, done in
      opened.urls.append(url)
      done("com.example.editor")
    }
    model.editing.settle = .milliseconds(10)
    model.editing.watchEvery = .seconds(60)
    return model
  }

  private func entry(_ path: String) -> FileEntry {
    FileEntry(
      name: String(path.split(separator: "/").last!), path: path, kind: .file, size: 3,
      modified: 1_700_000_000, permissions: 0o644)
  }

  /// An edit, as an editor saves it: new contents, a new modification time.
  private func save(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
  }

  private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  /// The copy's inode: what an app that has it open holds on to.
  private func node(_ url: URL) throws -> UInt64 {
    try #require((FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
  }

  @Test("opening edits a copy, and saving writes it back")
  func savingWritesBack() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    #expect(url.path.hasPrefix(model.editing.root.path), "an editing copy, not a preview")
    #expect(try text(url) == Self.notes, "the far side's contents")
    #expect(model.editing.records[Self.notes]?.editor == "com.example.editor")
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    try save("changed", to: url)
    await model.editing.check(Self.notes)
    #expect(source.writeBacks.map(\.contents) == ["changed"])
    #expect(model.editing.states[Self.notes] == .synced)
    await model.editing.check(Self.notes)
    #expect(source.writeBacks.count == 1, "nothing new to write")

    await model.edit([entry(Self.notes)])
    #expect(opened.urls == [url, url], "the same copy opens again")
    #expect(source.downloads.count == 1, "and is not fetched again")
  }

  /// Both sides changed. Each answer does what it says, and Later changes
  /// nothing until the next save.
  @Test("a change on both sides is the person's to settle", arguments: ["replace", "copy", "discard", nil])
  func conflict(answer: String?) async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    model.ask = { _ in PluginAnswer(action: answer) }
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    source.touch(Self.notes)
    try save("mine", to: url)
    let original = try node(url)
    await model.editing.check(Self.notes)

    switch answer {
    case "replace":
      #expect(source.writeBacks.map(\.contents) == ["mine"])
      #expect(model.editing.states[Self.notes] == .synced)
    case "copy":
      let copy = "/home/ada/notes (edited).txt"
      #expect(source.writeBacks.isEmpty, "the other change stays")
      #expect(source.uploads.map(\.1) == [copy])
      #expect(model.editing.records[copy] != nil, "the editor's next save goes to the copy")
      #expect(model.editing.records[Self.notes] == nil)
      #expect(try text(url) == "mine")
      try save("mine, again", to: url)
      await model.editing.check(copy)
      #expect(source.writeBacks.map(\.path) == [copy])
      #expect(source.writeBacks.map(\.contents) == ["mine, again"])
    case "discard":
      #expect(source.writeBacks.isEmpty)
      #expect(try text(url) == Self.notes, "the far side's contents")
      #expect(try node(url) == original, "the same file: the editor keeps its document")
      #expect(model.editing.states[Self.notes] == .synced)
    default:
      #expect(source.writeBacks.isEmpty)
      #expect(model.editing.states[Self.notes] == .conflict)
      #expect(try text(url) == "mine")
    }
  }

  /// Gone with its editor once everything is on the far side; kept, across
  /// tabs closing, while an edit is still to be written.
  @Test("a copy goes with its editor, never with an unsent edit")
  func lifetime() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)

    try save("unsent", to: url)
    model.editing.editorQuit("com.example.editor")
    #expect(FileManager.default.fileExists(atPath: url.path), "an edit not yet written back stays")
    await model.editing.check(Self.notes)
    model.editing.editorQuit("com.other.app")
    #expect(FileManager.default.fileExists(atPath: url.path), "another app quitting is not this one")
    model.editing.editorQuit("com.example.editor")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(model.editing.records.isEmpty)

    await model.edit([entry(Self.notes)])
    let again = try #require(opened.urls.last)
    model.editing.isRunning = { _ in true }
    model.close()
    #expect(FileManager.default.fileExists(atPath: again.path), "still open in its editor")
    model.editing.isRunning = { _ in false }
    model.editing.release()
    #expect(!FileManager.default.fileExists(atPath: again.path))
  }

  /// However the editor saves — over the same file, or a new one renamed
  /// over it — the save is noticed and written back on its own.
  @Test("a save is noticed however the editor writes it", arguments: [false, true])
  func noticesSaves(atomically: Bool) async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    try await Task.sleep(for: .milliseconds(50))
    if atomically {
      try Data("renamed over".utf8).write(to: url, options: .atomic)
    } else {
      let handle = try FileHandle(forWritingTo: url)
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: Data("written in place".utf8))
      try handle.close()
    }
    for _ in 0..<200 where source.writeBacks.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(source.writeBacks.map(\.contents) == [atomically ? "renamed over" : "written in place"])
  }

  /// A second check while one runs waits for it; it is not taken for a
  /// change on the far side.
  @Test("two checks at once write once, and see no conflict")
  func oneCheckAtATime() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    var asked = 0
    model.ask = { _ in asked += 1; return .cancelled }
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    try save("once", to: url)
    async let first: Void = model.editing.check(Self.notes)
    async let second: Void = model.editing.check(Self.notes)
    _ = await (first, second)
    try await Task.sleep(for: .milliseconds(100))
    #expect(source.writeBacks.map(\.contents) == ["once"])
    #expect(asked == 0)
    #expect(model.editing.states[Self.notes] == .synced)
  }

  /// Taking the far side's file is this side writing the copy, not an edit.
  @Test("discarding an edit is not itself written back")
  func discardIsQuiet() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    var asked = 0
    model.ask = { _ in asked += 1; return PluginAnswer(action: "discard") }
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    source.touch(Self.notes)
    try save("mine", to: url)
    await model.editing.check(Self.notes)
    try await Task.sleep(for: .milliseconds(200))
    #expect(asked == 1)
    #expect(source.writeBacks.isEmpty)
    #expect(model.editing.states[Self.notes] == .synced)
  }

  /// Another process of the same app may be the one with the copy open; an
  /// editor still starting has not said which app it is yet.
  @Test("a copy is kept while its editor may still have it")
  func keptWhileItMayBeOpen() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    model.openToEdit = { url, _ in opened.urls.append(url) }
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    model.editing.isRunning = { _ in false }
    model.editing.release()
    #expect(FileManager.default.fileExists(atPath: url.path), "no editor has reported in yet")
    model.editing.release(now: Date().addingTimeInterval(2 * EditingCopies.editorGrace))
    #expect(!FileManager.default.fileExists(atPath: url.path))

    await model.edit([entry(Self.notes)])
    let again = try #require(opened.urls.last)
    model.editing.opened(Self.notes, in: "com.example.editor")
    model.editing.editorQuit("com.example.editor", othersRunning: true)
    #expect(FileManager.default.fileExists(atPath: again.path))
  }

  /// An edit saved with no tab on its host waits for one, across launches.
  @Test("an edit with nowhere to go waits, and goes once a tab is back")
  func waitsForATab() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("editing-wait-\(UUID())")
    let host = UUID()
    let source = StubSource(tree)
    let opened = Opened()
    let first = tab(source, editing: EditingCopies(host: host, label: "lab", base: base), opened: opened)
    await first.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    first.editing.isRunning = { _ in true }
    first.close()
    try save("offline", to: url)
    await first.editing.check(Self.notes)
    #expect(first.editing.states[Self.notes] == .pending(nil))

    // The app opens again: the copy and its edit are still there.
    let reopened = EditingCopies(host: host, label: "lab", base: base)
    #expect(reopened.records[Self.notes] != nil)
    #expect(reopened.states[Self.notes] == .pending(nil))
    reopened.settle = .milliseconds(10)
    let second = tab(source, editing: reopened)
    _ = second
    for _ in 0..<100 where source.writeBacks.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(source.writeBacks.map(\.contents) == ["offline"])
  }

  @Test("something that would run is previewed, not opened in another app")
  func riskyIsPreviewed() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    await model.edit([entry("/home/ada/run.sh")])
    #expect(opened.urls.isEmpty)
    #expect(model.previewed.count == 1)
  }

  /// The watch stays on the file an editor replaced, so the next save goes too.
  @Test("a copy stays watched across saves")
  func staysWatched() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    try Data("one".utf8).write(to: url, options: .atomic)
    for _ in 0..<200 where source.writeBacks.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(source.writeBacks.map(\.contents) == ["one"])
    try Data("two".utf8).write(to: url, options: .atomic)
    for _ in 0..<200 where source.writeBacks.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(source.writeBacks.map(\.contents) == ["one", "two"])
    #expect(model.editing.states[Self.notes] == .synced)
  }

  /// While the copy still matches, the far side's edit replaces it, and that
  /// replacement is not itself written back. A save after that still goes.
  @Test("a change on the far side updates the open copy")
  func remoteChangeUpdatesTheCopy() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    model.editing.watchEvery = .milliseconds(20)
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    let original = try node(url)
    source.revise(Self.notes, "from the server")
    for _ in 0..<200 where (try? text(url)) != "from the server" {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try text(url) == "from the server")
    #expect(try node(url) == original, "the same file: an app that has it open is told it changed, not that it went")
    #expect(model.editing.states[Self.notes] == .synced)
    try await Task.sleep(for: .milliseconds(80))
    #expect(source.writeBacks.isEmpty, "bringing the far side in is not an edit")

    try save("and mine", to: url)
    for _ in 0..<200 where source.writeBacks.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(source.writeBacks.map(\.contents) == ["and mine"])
    #expect(model.editing.states[Self.notes] == .synced)
  }

  /// A save here and a change there is the conflict it always was. The watch
  /// does not fetch the far side over the save.
  @Test("a local edit is not replaced by a change on the far side")
  func remoteChangeLeavesALocalEdit() async throws {
    let source = StubSource(tree)
    let opened = Opened()
    let model = tab(source, opened: opened)
    var asked = 0
    model.ask = { _ in asked += 1; return .cancelled }
    model.editing.watchEvery = .milliseconds(20)
    await model.edit([entry(Self.notes)])
    let url = try #require(opened.urls.first)
    try save("mine", to: url)
    source.revise(Self.notes, "theirs")
    for _ in 0..<200 where model.editing.states[Self.notes] != .conflict {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try text(url) == "mine")
    #expect(model.editing.states[Self.notes] == .conflict)
    #expect(source.writeBacks.isEmpty)
    #expect(asked == 1)
  }

  @Test("a file on this machine opens as itself")
  func localOpensInPlace() async throws {
    let source = StubSource(tree)
    source.isLocal = true
    let opened = Opened()
    let model = tab(source, opened: opened)
    await model.edit([entry(Self.notes)])
    #expect(opened.urls == [URL(fileURLWithPath: Self.notes)])
    #expect(model.editing.records.isEmpty)
  }
}

/// The write-back itself, over this machine's own `sftp-server`: what a real
/// server does with permissions, links and a file changed underneath.
@Suite("writing back over SFTP", .serialized, .enabled(if: TerminalSession.isLocalAvailable))
struct WriteBackTests {
  private func files() async throws -> (TerminalSession, RemoteFiles) {
    let session = try await TerminalSession.local()
    let connection = try #require(session.connection)
    return (session, try await connection.files())
  }

  private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("write-back-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  @Test("a script written back is still a script")
  func keepsPermissions() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (session, remote) = try await files()
    defer { session.close() }
    let script = folder.appendingPathComponent("run.sh")
    try Data("echo one\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: script.path)
    let before = try await remote.stat(script.path)
    let edited = folder.appendingPathComponent("edited")
    try Data("echo two\n".utf8).write(to: edited)

    let after = try await remote.writeBack(edited.path, to: script.path, expected: before)
    #expect(try String(contentsOf: script, encoding: .utf8) == "echo two\n")
    #expect(after.permissions & 0o777 == 0o750)
    #expect(try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int == 0o750)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty, "no working file left behind")
  }

  @Test("a file changed on the far side is not overwritten")
  func refusesAChangedFile() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (session, remote) = try await files()
    defer { session.close() }
    let notes = folder.appendingPathComponent("notes.txt")
    try Data("first".utf8).write(to: notes)
    let before = try await remote.stat(notes.path)
    try Data("someone else's".utf8).write(to: notes)
    let edited = folder.appendingPathComponent("edited")
    try Data("mine".utf8).write(to: edited)

    await #expect(throws: FileError.changed(path: notes.path)) {
      _ = try await remote.writeBack(edited.path, to: notes.path, expected: before)
    }
    #expect(try String(contentsOf: notes, encoding: .utf8) == "someone else's")
  }

  @Test("a link is written through, not replaced")
  func writesThroughALink() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (session, remote) = try await files()
    defer { session.close() }
    let target = folder.appendingPathComponent("target.txt")
    let link = folder.appendingPathComponent("link.txt")
    try Data("old".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let before = try await remote.stat(link.path)
    let edited = folder.appendingPathComponent("edited")
    try Data("new".utf8).write(to: edited)

    _ = try await remote.writeBack(edited.path, to: link.path, expected: before)
    #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
  }
}
