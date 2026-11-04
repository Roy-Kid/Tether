import Foundation
import SwiftUI
import Testing
import Tether
import TetherPluginKit

@testable import FilesPlugin

/// A tab as the host would hand it over, recording what was typed at its
/// prompt. No connection: the browser's far side is a `StubSource`.
@MainActor
private final class HostProbe {
  var typed: [String] = []
  var shown = 0
  var focused = 0
  var workingDirectory: String?
  var paneDirectory: String?
  var directoryGate: Gate?
  var directoryRequests = 0

  func context() -> TabContext {
    TabContext(
      id: UUID(),
      plugin: PluginContext(
        connection: nil, hostLabel: "lab", hostID: UUID(),
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: { [weak self] in self?.focused += 1 }, dismissAccessory: {}, present: { _ in }, dismissSheet: {},
      insertText: { [weak self] in self?.typed.append($0) },
      workingDirectory: { [weak self] in self?.workingDirectory },
      resolveWorkingDirectory: { [weak self] _ in
        self?.directoryRequests += 1
        await self?.directoryGate?.wait()
        return self?.paneDirectory ?? self?.workingDirectory
      },
      showAccessory: { [weak self] in self?.shown += 1 })
  }
}

/// Editing copies of a host nobody else has, in a folder of the test's own:
/// never the real Application Support.
@MainActor
func scratchEditing() -> EditingCopies {
  let copies = EditingCopies(
    host: UUID(), label: "lab",
    base: FileManager.default.temporaryDirectory.appendingPathComponent("files-editing-\(UUID())"))
  // The watch asks the far side on its own. A test that is not about that
  // leaves it quiet, so a touch meant for one check is not fetched first.
  copies.watchEvery = .seconds(60)
  return copies
}

private func scratchCache() -> FileCache {
  FileCache(
    host: UUID(),
    base: FileManager.default.temporaryDirectory.appendingPathComponent("files-tests-\(UUID())"))
}

/// A defaults suite with nothing set, so a threshold changed on this Mac
/// does not change what the tests ask.
func cleanDefaults() -> UserDefaults {
  let name = "FilesPluginTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}

@MainActor
private func browser(
  _ source: StubSource, host: HostProbe = HostProbe(), defaults: UserDefaults = cleanDefaults()
) -> FilesTab {
  let model = FilesTab(
    tab: host.context(), cache: scratchCache(), editing: scratchEditing(), open: { _ in source },
    present: { _ in }, defaults: defaults)
  model.revealSaved = { _ in }
  model.openLocal = { _ in }
  model.openToEdit = { _, opened in opened("com.example.editor") }
  return model
}

private func pointed(_ printed: String, in directory: String? = nil) -> PointedLink {
  PointedLink(
    link: TerminalLink(
      text: printed, kind: .path(path: printed, line: nil, column: nil),
      spans: [LinkSpan(row: 0, start: 0, end: UInt16(printed.count))]),
    directory: { directory })
}

@MainActor
private func settle(_ model: FilesTab, until: () -> Bool) async throws {
  for _ in 0..<200 where !until() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(until())
}

@MainActor
@Suite("files on a tab")
struct FilesTabTests {
  let tree: [String: FileKind] = [
    "/": .directory, "/home": .directory, "/home/ada": .directory,
    "/home/ada/runs": .directory, "/home/ada/b.txt": .file, "/home/ada/A.png": .file,
    "/home/ada/.env": .file, "/home/ada/runs/plot.png": .file,
  ]

  @Test("the browser starts at home, folders first, dot-files hidden until asked")
  func startsAtHome() async throws {
    let model = browser(StubSource(tree))
    model.appear()
    try await settle(model) { model.directory == "/home/ada" }
    #expect(model.visible.map(\.name) == ["runs", "A.png", "b.txt"])
    model.showHidden = true
    #expect(model.visible.first?.name == "runs", "a folder still leads")
    #expect(Set(model.visible.map(\.name)) == [".env", "runs", "A.png", "b.txt"])
  }

  @Test("wrappers of the same lease keep files open",
    .enabled(if: TerminalSession.isLocalAvailable))
  func connectionIdentityUsesLease() async throws {
    let shell = try await TerminalSession.local()
    defer { shell.close() }
    let connection = try #require(shell.connection)
    let context = TabContext(
      id: UUID(),
      plugin: PluginContext(connection: connection, hostLabel: "local", hostID: UUID(),
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {}, insertText: { _ in })
    var sources: [StubSource] = []
    let model = FilesTab(tab: context, cache: scratchCache(), editing: scratchEditing(),
      open: { _ in
        let source = StubSource(tree)
        sources.append(source)
        return source
      }, present: { _ in }, defaults: cleanDefaults())
    defer { model.close() }
    await model.go(to: "/home/ada/runs")
    let wrapper = try #require(shell.connection)
    #expect(wrapper !== connection)
    #expect(wrapper.leaseID() == connection.leaseID())
    model.connectionChanged(wrapper)
    await Task.yield()
    #expect(sources.count == 1)
    #expect(!sources[0].closed)

    #expect(model.directory == "/home/ada/runs")
    #expect(model.entries.map(\.name) == ["plot.png"])
    #expect(model.problem == nil)
  }

  @Test("an upload never overwrites: a taken name is asked about")
  func uploadConflictIsAsked() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("b.txt")
    try Data("x".utf8).write(to: local)

    let arrived = await model.upload([local], into: "/home/ada")
    #expect(arrived.isEmpty)
    #expect(source.uploads.isEmpty)
    let conflict = try #require(model.conflicts.first)
    #expect(conflict.target == "/home/ada/b.txt")

    await model.resolve(conflict, .keepBoth)
    #expect(source.uploads.map(\.1) == ["/home/ada/b 2.txt"])
    #expect(model.conflicts.isEmpty)
  }

  @Test("nothing is deleted until it is confirmed, and a folder goes as a tree")
  func deletionIsConfirmed() async {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    let runs = model.entries.first { $0.name == "runs" }!
    let text = model.entries.first { $0.name == "b.txt" }!

    model.requestDelete([runs, text])
    #expect(source.has("/home/ada/runs"), "asking deletes nothing")
    await model.confirmDelete()
    #expect(source.removedTrees == ["/home/ada/runs"])
    #expect(source.removed == ["/home/ada/b.txt"])
    #expect(!model.visible.contains { $0.name == "runs" })
  }

  @Test("a rename to a taken name is refused, not replaced")
  func renameRefusesTakenName() async {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    let text = model.entries.first { $0.name == "b.txt" }!
    await model.rename(text, to: "A.png")
    #expect(source.renames.isEmpty)
    #expect(source.has("/home/ada/b.txt"))
    #expect(model.problem == "“A.png” already exists.")

    await model.rename(text, to: "../escape")
    #expect(source.renames.isEmpty, "a name with a slash is not a name")
    #expect(source.has("/home/ada/b.txt"))
  }

  @Test("files dropped on the terminal arrive where the browser is, then are typed")
  func dropUploadsThenTypes() async throws {
    let source = StubSource(tree)
    let host = HostProbe()
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("my shot.png")
    try Data("x".utf8).write(to: local)

    let unopened = browser(source, host: host)
    #expect(!unopened.receive(files: [local]), "no lease and no session: the next plugin tries")

    let model = browser(source, host: host)
    await model.go(to: "/home/ada/runs")
    #expect(model.receive(files: [local]))
    try await settle(model) { !host.typed.isEmpty }
    #expect(host.typed == ["'/home/ada/runs/my shot.png' "])
    #expect(source.has("/home/ada/runs/my shot.png"))
  }

  @Test("previewing fetches once, then uses the copy until the file changes")
  func previewUsesTheCache() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    let image = model.entries.first { $0.name == "A.png" }!
    await model.preview([image])
    let first = try #require(model.previewed.first)
    #expect(try String(contentsOf: first, encoding: .utf8) == "/home/ada/A.png")
    #expect(model.cache.cached(image) == first)
    #expect(model.transfers.items.isEmpty, "a finished copy leaves the list")

    await model.preview([image])
    #expect(source.downloads.count == 1, "the same modification time is not fetched again")
    #expect(model.previewed.first == first)

    source.modifiedAt["/home/ada/A.png"] = 1_700_000_001
    await model.preview([image])
    let second = try #require(model.previewed.first)
    #expect(source.downloads.count == 2, "a newer modification time is fetched")
    #expect(second != first)
    #expect(try String(contentsOf: second, encoding: .utf8) == "/home/ada/A.png")
  }

  @Test("a download copies a folder, including an empty one and a hidden file")
  func downloadCopiesAFolder() async throws {
    var files = tree
    files["/home/ada/runs/nested"] = .directory
    files["/home/ada/runs/nested/note.txt"] = .file
    files["/home/ada/runs/empty"] = .directory
    files["/home/ada/runs/.secret"] = .file
    files["/home/ada/runs/link"] = .link
    let source = StubSource(files)
    let asking = browser(source)
    await asking.go(to: "/home/ada")
    let runs = try #require(asking.entries.first { $0.name == "runs" })
    asking.download([runs])
    #expect(asking.pendingSave.map(\.path) == ["/home/ada/runs"])
    #expect(source.downloads.isEmpty)

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("files-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = cleanDefaults()
    defaults.set(folder.path, forKey: FilesPreferences.directoryKey)
    let saving = browser(source, defaults: defaults)
    var revealed = false
    saving.revealSaved = { _ in revealed = true }
    await saving.go(to: "/home/ada")
    let again = try #require(saving.entries.first { $0.name == "runs" })
    saving.download([again])
    try await settle(saving) { revealed }
    #expect(source.downloads.count == 3)
    let saved = folder.appendingPathComponent("runs")
    #expect(try Data(contentsOf: saved.appendingPathComponent("plot.png")) == Data("/home/ada/runs/plot.png".utf8))
    #expect(
      try Data(contentsOf: saved.appendingPathComponent("nested/note.txt"))
        == Data("/home/ada/runs/nested/note.txt".utf8))
    #expect(try Data(contentsOf: saved.appendingPathComponent(".secret")) == Data("/home/ada/runs/.secret".utf8))
    var empty = ObjCBool(false)
    #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("empty").path, isDirectory: &empty))
    #expect(empty.boolValue)
    #expect(!FileManager.default.fileExists(atPath: saved.appendingPathComponent("link").path))
    #expect(saving.problem == nil)
  }

  @Test("a download moves the preview copy instead of fetching again")
  func downloadMovesThePreview() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    let image = try #require(model.entries.first { $0.name == "A.png" })
    await model.preview([image])
    let cached = try #require(model.cache.cached(image))
    let bytes = try Data(contentsOf: cached)
    #expect(source.downloads.count == 1)

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("files-move-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    await model.save([image], to: folder)
    #expect(source.downloads.count == 1, "the preview copy moved")
    #expect(model.cache.cached(image) == nil)
    #expect(!FileManager.default.fileExists(atPath: cached.path))
    #expect(try Data(contentsOf: folder.appendingPathComponent("A.png")) == bytes)
  }

  @Test("closing the tab closes its file session")
  func closeClosesTheSession() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    model.close()
    // The session closes on a task of its own. A fixed sleep was a guess at
    // how long a loaded runner takes; this waits for it, up to five seconds.
    for _ in 0..<500 where !source.closed { try await Task.sleep(for: .milliseconds(10)) }
    #expect(source.closed)
  }

  @Test("pointing at a file focuses Files; at a directory, shows the browser there")
  func lookingAtALink() async {
    let source = StubSource(tree)
    let host = HostProbe()
    host.workingDirectory = "/home/ada"
    let model = browser(source, host: host)
    await model.go(to: "/home/ada")

    await model.look(at: .at("runs/plot.png", in: "/home/ada"))
    #expect(model.previewed.map(\.lastPathComponent) == ["plot.png"])
    #expect(host.shown == 1, "a file opens in Quick Look with Files focused")
    #expect(host.focused == 1)

    await model.look(at: .at("runs", in: "/home/ada"))
    #if os(macOS)
      // A tree: the folder opens in place, the root stays.
      #expect(model.directory == "/home/ada")
      #expect(model.expanded.contains("/home/ada/runs"))
      #expect(model.selection == ["/home/ada/runs"])
    #else
      #expect(model.directory == "/home/ada/runs")
    #endif
    #expect(host.shown == 2)
    #expect(host.focused == 2)

    await model.reveal(.at("/home/ada/b.txt"))
    #expect(model.directory == "/home/ada")
    #expect(model.selection == ["/home/ada/b.txt"])
  }

  @Test("hovering asks whether the path is really there, before underlining it")
  func existsIsAsked() async throws {
    let model = browser(StubSource(tree))
    await model.go(to: "/home/ada")
    let there = try #require(model.actions(for: pointed("plot.png", in: "/home/ada/runs")))
    let absent = try #require(model.actions(for: pointed("and/or")))
    #expect(await there.exists?() == true)
    #expect(await absent.exists?() == false)
  }

}

@Suite("the preview cache")
struct FileCacheTests {
  private func entry(_ path: String, size: UInt64 = 3, modified: UInt64? = 1) -> FileEntry {
    FileEntry(
      name: String(path.split(separator: "/").last!), path: path, kind: .file, size: size,
      modified: modified, permissions: 0o644)
  }

  /// Not `/tmp`, which every account on the Mac can read.
  @Test("previews are kept where only this account can read them")
  func previewsArePrivate() throws {
    let cache = FileCache(host: UUID())
    #expect(cache.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(!cache.root.path.hasPrefix("/tmp/"))
    let scratch = scratchCache()
    let folder = scratch.location(for: entry("/a/plot.png")).deletingLastPathComponent()
    let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    let copy = folder.appendingPathComponent("plot.png")
    try Data("png".utf8).write(to: copy)
    scratch.keep(copy)
    #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
  }

  /// The pass launch repeats. A preview still inside the age and the limit
  /// stays; one that ages afterwards goes on the next pass, and so does the
  /// least recently looked at once the copies no longer fit. An editing copy
  /// is not in this root.
  @Test("a later sweep removes what aged, and what no longer fits")
  func sweepsAgain() throws {
    #expect(LocalCopies.sweepEvery == 10 * 60)
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("files-again-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let cache = FileCache(host: UUID(), base: base)
    let kept = entry("/kept.bin")
    try Data(count: 10).write(to: cache.location(for: kept))
    let editing = base.appendingPathComponent("Editing/note.txt")
    try FileManager.default.createDirectory(
      at: editing.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: editing)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-2 * LocalCopies.previewAge)], ofItemAtPath: editing.path)

    LocalCopies.sweep(base: base)
    #expect(cache.cached(kept) != nil)
    #expect(FileManager.default.fileExists(atPath: editing.path))

    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-2 * LocalCopies.previewAge)],
      ofItemAtPath: cache.location(for: kept).deletingLastPathComponent().path)
    LocalCopies.sweep(base: base)
    #expect(cache.cached(kept) == nil)
    #expect(FileManager.default.fileExists(atPath: editing.path))

    let older = entry("/older.bin"), newer = entry("/newer.bin")
    try Data(count: 800).write(to: cache.location(for: older))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-120)],
      ofItemAtPath: cache.location(for: older).deletingLastPathComponent().path)
    try Data(count: 800).write(to: cache.location(for: newer))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-30)],
      ofItemAtPath: cache.location(for: newer).deletingLastPathComponent().path)
    LocalCopies.trimPreviews(
      in: LocalCopies.previews(in: base), limit: 1000, maxAge: LocalCopies.previewAge)
    #expect(cache.cached(older) == nil)
    #expect(cache.cached(newer) != nil)
  }

  @Test("a hostile name stays inside the cache")
  func namesStayInside() {
    let cache = scratchCache()
    let url = cache.location(for: entry("/x/..") )
    #expect(url.lastPathComponent == "file")
    #expect(url.path.hasPrefix(cache.root.path))
  }

}
