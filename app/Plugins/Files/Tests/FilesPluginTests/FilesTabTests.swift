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

  func context() -> TabContext {
    TabContext(
      id: UUID(),
      plugin: PluginContext(
        connection: nil, hostLabel: "lab", hostID: UUID(),
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: { [weak self] in self?.focused += 1 }, dismissAccessory: {}, present: { _ in }, dismissSheet: {},
      insertText: { [weak self] in self?.typed.append($0) },
      workingDirectory: { [weak self] in self?.workingDirectory },
      showAccessory: { [weak self] in self?.shown += 1 })
  }
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
    tab: host.context(), cache: scratchCache(), open: { _ in source }, present: { _ in },
    defaults: defaults)
  model.revealSaved = { _ in }
  model.openLocal = { _ in }
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

  @Test("a reopened tab restores the browser's directory on a fresh attachment")
  func restoreDirectory() async throws {
    let original = browser(StubSource(tree))
    await original.go(to: "/home/ada/runs")
    let state = try #require(original.restorationState)
    original.close()
    let restored = browser(StubSource(tree))
    defer { restored.close() }
    restored.restore(from: state)
    try await settle(restored) { restored.directory == "/home/ada/runs" }
    #expect(restored.entries.map(\.name) == ["plot.png"])
    #expect(restored.transfers.running == 0)
  }

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

  @Test("the browser opens where the shell is, and home when that is not listable")
  func startsWhereTheShellIs() async throws {
    let host = HostProbe()
    host.workingDirectory = "/home/ada/runs"
    let model = browser(StubSource(tree), host: host)
    model.appear()
    try await settle(model) { model.directory == "/home/ada/runs" }

    host.workingDirectory = "/gone"
    let fallback = browser(StubSource(tree), host: host)
    fallback.appear()
    try await settle(fallback) { fallback.directory == "/home/ada" }
    #expect(fallback.problem == nil)
  }

  @Test("a replaced lease lists the open directory again")
  func relistsAfterReconnect() async throws {
    let source = StubSource(tree)
    let host = HostProbe()
    var opens = 0
    let model = FilesTab(
      tab: host.context(), cache: scratchCache(),
      open: { _ in
        opens += 1
        return source
      }, present: { _ in }, defaults: cleanDefaults())
    await model.go(to: "/home/ada")
    #expect(opens == 1)
    model.reopen()
    try await settle(model) { opens >= 2 && model.directory == "/home/ada" }
    #expect(model.problem == nil)
    #expect(model.visible.map(\.name).contains("A.png"))
  }

  @Test("a lease that arrives after a failed open still lists")
  func listsWhenTheLeaseArrivesLate() async throws {
    let source = StubSource(tree)
    let host = HostProbe()
    var live = false
    let model = FilesTab(
      tab: host.context(), cache: scratchCache(),
      open: { _ in
        if !live { throw FileError.disconnected(cause: "No connection.") }
        return source
      }, present: { _ in }, defaults: cleanDefaults())
    model.appear()
    try await settle(model) { model.problem != nil }
    #expect(model.directory == nil)
    live = true
    model.reopen()
    try await settle(model) { model.directory == "/home/ada" }
    #expect(model.problem == nil)
  }

  @Test("into a folder, up, and back retrace the way")
  func navigation() async throws {
    let model = browser(StubSource(tree))
    await model.go(to: "/home/ada")
    await model.go(to: "/home/ada/runs")
    #expect(model.history == ["/home/ada"])
    model.up()
    try await settle(model) { model.directory == "/home/ada" }
    #expect(model.history == ["/home/ada", "/home/ada/runs"])
    model.back()
    try await settle(model) { model.directory == "/home/ada/runs" }
    #expect(model.history == ["/home/ada"])
  }

  @Test("a listing that finishes late does not take the browser back")
  func staleListingIsDropped() async throws {
    let source = StubSource(tree)
    source.listDelay["/home"] = .milliseconds(200)
    let model = browser(source)
    let slow = Task { await model.go(to: "/home") }
    try await Task.sleep(for: .milliseconds(20))
    await model.go(to: "/home/ada/runs")
    await slow.value
    #expect(model.directory == "/home/ada/runs")
  }

  @Test("a directory that is not there says so in one line and keeps the listing")
  func missingDirectory() async {
    let model = browser(StubSource(tree))
    await model.go(to: "/home/ada")
    await model.go(to: "/nowhere")
    #expect(model.directory == "/home/ada")
    #expect(model.problem == "“nowhere” does not exist.")
    #expect(!model.visible.isEmpty)
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

  @Test("replacing is a choice the person made, and only then")
  func replaceWhenChosen() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("A.png")
    try Data("x".utf8).write(to: local)
    await model.upload([local], into: "/home/ada")
    await model.resolve(try #require(model.conflicts.first), .replace)
    #expect(source.uploads.map(\.2) == [true])
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

  @Test("a new folder gets a free name and is ready to be renamed")
  func newFolder() async throws {
    let source = StubSource(tree.merging(["/home/ada/untitled folder": .directory]) { $1 })
    let model = browser(source)
    await model.go(to: "/home/ada")
    model.newFolder()
    try await settle(model) { model.renaming != nil }
    #expect(model.renaming == "/home/ada/untitled folder 2")
    #expect(source.has("/home/ada/untitled folder 2"))
  }

  @Test("dragging a file or a folder carries the absolute path Copy Path would copy")
  func dragCarriesAbsolutePath() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    let image = try #require(model.entries.first { $0.name == "A.png" })
    let folder = try #require(model.entries.first { $0.name == "runs" })
    let text = try #require(model.entries.first { $0.name == "b.txt" })
    #expect(model.draggedPathText(image) == "/home/ada/A.png")
    #expect(model.draggedPathText(folder) == "/home/ada/runs")
    #expect(folder.kind == .directory)
    model.selection = [image.path, text.path]
    #expect(model.draggedPathText(image) == "/home/ada/A.png\n/home/ada/b.txt")
    #expect(model.draggedPathText(folder) == "/home/ada/runs", "a row outside the selection is only itself")

    let dragged = DraggedFile(
      text: model.draggedPathText(image), file: RemoteFile(model: model, entry: image))
    let provider = NSItemProvider()
    provider.register(dragged)
    #expect(provider.registeredTypeIdentifiers.contains(DroppedPath.contentType.identifier))
    let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<DroppedPath?, Never>) in
      _ = provider.loadTransferable(type: DroppedPath.self) { result in
        continuation.resume(returning: try? result.get())
      }
    }
    #expect(loaded?.text == "/home/ada/A.png\n/home/ada/b.txt")
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

  @Test("Quick Look opens before an uncached remote file finishes downloading")
  func previewOpensWhileDownloading() async throws {
    let source = StubSource(tree)
    source.downloadDelay = .seconds(1)
    var shown: [[URL]] = []
    let host = HostProbe()
    let model = FilesTab(
      tab: host.context(), cache: scratchCache(), open: { _ in source },
      present: { shown.append($0) }, defaults: cleanDefaults())
    await model.go(to: "/home/ada")
    let file = try #require(model.entries.first { $0.name == "A.png" })

    let fetching = Task { await model.preview([file]) }
    try await settle(model) { !shown.isEmpty }
    #expect(shown.count == 1)
    let placeholderFolder = shown[0].first?.deletingLastPathComponent()
      .deletingLastPathComponent().lastPathComponent
    #expect(placeholderFolder == "Tether Preview Loading")

    await fetching.value
    #expect(shown.count == 2)
    #expect(shown[1].first?.lastPathComponent == "A.png")
  }

  @Test("a large file asks before it is fetched")
  func largeFileAsks() async {
    let model = browser(StubSource(tree))
    let huge = FileEntry(
      name: "movie.mov", path: "/home/ada/movie.mov", kind: .file,
      size: FilesTab.previewLimit + 1, modified: nil, permissions: 0o644)
    await model.preview([huge])
    #expect(model.pendingLarge == huge)
    #expect(model.pendingFetch == .preview([huge]))
    #expect(model.previewed.isEmpty)
  }

  @Test("a large file already in the cache does not ask again")
  func cachedLargeFileDoesNotAsk() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    let huge = FileEntry(
      name: "movie.mov", path: "/home/ada/movie.mov", kind: .file,
      size: FilesTab.previewLimit + 1, modified: nil, permissions: 0o644)
    try Data("mov".utf8).write(to: model.cache.location(for: huge))
    await model.preview([huge])
    #expect(model.pendingLarge == nil)
    #expect(source.downloads.isEmpty)
    await model.openFetched([huge])
    #expect(model.pendingLarge == nil)
    #expect(source.downloads.isEmpty)
  }

  @Test("a file at the limit is fetched without asking")
  func fileAtTheLimitDoesNotAsk() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    let exact = FileEntry(
      name: "clip.mov", path: "/home/ada/clip.mov", kind: .file,
      size: FilesTab.previewLimit, modified: nil, permissions: 0o644)
    await model.preview([exact])
    #expect(model.pendingLarge == nil)
    #expect(source.downloads.count == 1)
  }

  @Test("the size gate is the one set in preferences")
  func promptLimitFollowsTheSetting() async {
    let defaults = cleanDefaults()
    defaults.set(1, forKey: FilesPreferences.promptKey)
    let model = browser(StubSource(tree), defaults: defaults)
    let small = FileEntry(
      name: "a.txt", path: "/a.txt", kind: .file, size: 1_000_000, modified: nil, permissions: 0o644)
    let large = FileEntry(
      name: "b.txt", path: "/b.txt", kind: .file, size: 1_000_001, modified: nil, permissions: 0o644)
    await model.preview([small])
    #expect(model.pendingLarge == nil)
    await model.preview([large])
    #expect(model.pendingLarge == large)
  }

  @Test("a large file on this machine is shown without asking")
  func localLargeFileDoesNotAsk() async {
    let source = StubSource(tree)
    source.isLocal = true
    let model = browser(source)
    let huge = FileEntry(
      name: "movie.mov", path: "/home/ada/movie.mov", kind: .file,
      size: FilesTab.previewLimit + 1, modified: nil, permissions: 0o644)
    await model.preview([huge])
    #expect(model.pendingLarge == nil)
    #expect(model.previewed == [URL(fileURLWithPath: huge.path)])
    #expect(source.downloads.isEmpty)
  }

  @Test("opening a large file asks before it is fetched")
  func openAsksForALargeFile() async {
    let source = StubSource(tree)
    let model = browser(source)
    let huge = FileEntry(
      name: "movie.mov", path: "/home/ada/movie.mov", kind: .file,
      size: FilesTab.previewLimit + 1, modified: nil, permissions: 0o644)
    await model.openFetched([huge])
    #expect(model.pendingLarge == huge)
    #expect(model.pendingFetch == .open([huge]))
    #expect(source.downloads.isEmpty)
  }

  @Test("a download asks where to save, unless a folder is set")
  func downloadAsksUnlessAFolderIsSet() async throws {
    let source = StubSource(tree)
    let asking = browser(source)
    await asking.go(to: "/home/ada")
    let image = try #require(asking.entries.first { $0.name == "A.png" })
    asking.download([image])
    #expect(asking.pendingSave == [image])
    #expect(source.downloads.isEmpty)

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("files-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let defaults = cleanDefaults()
    defaults.set(folder.path, forKey: FilesPreferences.directoryKey)
    let saving = browser(source, defaults: defaults)
    await saving.go(to: "/home/ada")
    let again = try #require(saving.entries.first { $0.name == "A.png" })
    saving.download([again])
    try await settle(saving) { source.downloads.count == 1 }
    #expect(saving.pendingSave.isEmpty)
    let saved = folder.appendingPathComponent("A.png")
    #expect(FileManager.default.fileExists(atPath: saved.path))
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

  @Test("closing the tab with a copy in flight says what stops, and stops it")
  func closeNoteCountsTransfers() async throws {
    let source = StubSource(tree)
    source.downloadDelay = .seconds(30)
    let model = browser(source)
    await model.go(to: "/home/ada")
    #expect(model.closeNote == nil)
    #expect(!model.requiresCloseConfirmation)

    let fetching = Task { await model.preview([model.entries.first { $0.name == "A.png" }!]) }
    try await settle(model) { model.transfers.running == 1 }
    #expect(model.closeNote == "1 transfer stops.")
    #expect(model.requiresCloseConfirmation)
    // Progress arrives on a later hop to the main actor than the row does.
    try await settle(model) { model.transfers.items.first?.done == 1 }

    model.close()
    await fetching.value
    #expect(model.transfers.items.isEmpty, "a stopped copy is not a failure to show")
    #expect(!model.requiresCloseConfirmation)
    #expect(model.previewed.isEmpty)
  }

  @Test("closing the tab closes its file session")
  func closeClosesTheSession() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    model.close()
    try await Task.sleep(for: .milliseconds(50))
    #expect(source.closed)
  }

  @Test("a printed path is looked for where the shell is, then the browser, then home")
  func relativePathsResolveInOrder() async throws {
    let source = StubSource(
      tree.merging([
        "/srv": .directory, "/srv/job": .directory, "/srv/job/out.csv": .file,
        "/home/ada/runs/out.csv": .file,
      ]) { $1 })
    let host = HostProbe()
    let model = browser(source, host: host)
    await model.go(to: "/home/ada/runs")

    #expect(await model.resolve(.at("out.csv"))?.path == "/home/ada/runs/out.csv", "the browser")
    #expect(
      await model.resolve(.at("out.csv", in: "/srv/job"))?.path == "/srv/job/out.csv",
      "where it was printed, first")
    #expect(await model.resolve(.at("./out.csv", in: "/srv/job"))?.path == "/srv/job/out.csv")
    #expect(await model.resolve(.at("b.txt", in: "/srv/job"))?.path == "/home/ada/b.txt", "home, last")
    #expect(await model.resolve(.at("~/A.png"))?.path == "/home/ada/A.png")
    #expect(await model.resolve(.at("nowhere.txt")) == nil)
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

  @Test("a path that is nowhere opens nothing")
  func missingLinkOpensNothing() async {
    let host = HostProbe()
    let model = browser(StubSource(tree), host: host)
    await model.go(to: "/home/ada")
    await model.look(at: .at("not/there.png"))
    #expect(model.previewed.isEmpty)
    #expect(host.shown == 0)
    #expect(host.focused == 0)
  }

  @Test("a web address is not a file; a file:// hyperlink is")
  func whichLinksAreFiles() async {
    let model = browser(StubSource(tree))
    #expect(model.actions(for: pointed("plot.png")) == nil, "no lease, no session: nothing to offer")
    await model.go(to: "/home/ada")
    #expect(model.actions(for: pointed("plot.png")) != nil)
    let web = TerminalLink(
      text: "docs", kind: .url(url: "https://example.org"), spans: [])
    #expect(model.actions(for: PointedLink(link: web, directory: { nil })) == nil)
    let file = TerminalLink(
      text: "report", kind: .hyperlink(uri: "file://lab/home/ada/My%20Report.pdf"), spans: [])
    #expect(FilesTab.printedPath(file) == "/home/ada/My Report.pdf")
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

  @Test("a local preview follows the file's modification time")
  func localPreviewFollowsModificationTime() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("files-mtime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("plot.png")
    try Data("one".utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)

    let source = StubSource([folder.path: .directory, file.path: .file])
    source.isLocal = true
    let model = browser(source)
    let entry = FileEntry(
      name: "plot.png", path: file.path, kind: .file, size: 3, modified: 1, permissions: 0o644)

    await model.preview([entry])
    let first = try #require(model.previewed.first)
    #expect(first.path != file.path)
    #expect(try String(contentsOf: first, encoding: .utf8) == "one")

    try Data("two".utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
    await model.preview([entry])
    #expect(model.previewed.first == first)

    try Data("three".utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_700_000_005)], ofItemAtPath: file.path)
    await model.preview([entry])
    let second = try #require(model.previewed.first)
    #expect(second != first)
    #expect(try String(contentsOf: second, encoding: .utf8) == "three")
    #expect(source.downloads.isEmpty)
  }

  @Test("on this machine a file is shown where it is, never copied")
  func localFilesAreShownInPlace() async throws {
    let source = StubSource(tree)
    source.isLocal = true
    let model = browser(source)
    await model.go(to: "/home/ada")
    let image = model.entries.first { $0.name == "A.png" }!
    #expect(try await model.local(image) == URL(fileURLWithPath: "/home/ada/A.png"))
    #expect(model.cache.cached(image) == nil, "nothing went into the cache")
  }

  @Test("the accessory lives in the inspector")
  func accessoryPlacement() {
    #expect(FilesPlugin().accessory.placement == .inspector)
  }

  @Test("a pasted relative path is resolved from the shell, then the browser")
  func pastedPathUsesTheShell() async throws {
    let relative = "lab-new/projects/pcl-ptmc-pec-tg/figures/hotmelt-rho.png"
    let underShell = "/home/ada/runs/" + relative
    let underBrowser = "/home/ada/" + relative
    var files = tree
    for path in [underShell, underBrowser] {
      var cursor = ""
      for part in path.split(separator: "/") {
        cursor += "/" + part
        if cursor.hasSuffix(".png") {
          files[cursor] = .file
        } else if files[cursor] == nil {
          files[cursor] = .directory
        }
      }
    }
    let source = StubSource(files)
    let host = HostProbe()
    host.workingDirectory = "/home/ada/runs"
    let model = browser(source, host: host)
    await model.go(to: "/home/ada")
    let listed = source.stats.count

    model.beginFind()
    model.query = relative
    model.noteQueryChange(from: "")
    try await settle(model) { model.selection == [underShell] }
    #if os(macOS)
      #expect(model.directory == "/home/ada", "the file is under the root, so the root stays")
    #else
      #expect(model.directory == Paths.parent(underShell))
    #endif
    #expect(!model.finding)
    #expect(source.stats.dropFirst(listed).first == underShell)
    let stayed = model.directory

    model.beginFind()
    model.query = "lab-new/missing.png"
    model.noteQueryChange(from: "")
    try await settle(model) { source.stats.last == "/home/ada/lab-new/missing.png" }
    #expect(model.finding, "nothing by that name, so the field stays")
    #expect(model.directory == stayed)
  }

  @Test("typing a path does not look it up; a name filters rows already listed")
  func typedPathWaitsAndNameDoesNotStat() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    await model.go(to: "/home/ada")
    let listed = source.stats.count

    model.beginFind()
    var previous = ""
    for next in ["l", "la", "lab", "lab/"] {
      model.query = next
      model.noteQueryChange(from: previous)
      previous = next
    }
    #expect(model.finding)
    #expect(source.stats.count == listed, "a typed slash is not a search of the far side")

    model.query = "plot"
    model.noteQueryChange(from: "lab/")
    #expect(model.displayedRows.isEmpty, "plot.png is inside a folder that is not open")
    #expect(source.stats.count == listed)

    model.query = "a.png"
    model.noteQueryChange(from: "plot")
    #expect(model.displayedRows.map(\.entry.name) == ["A.png"])
    #expect(model.selection == ["/home/ada/A.png"])
    model.query = ".env"
    model.noteQueryChange(from: "a.png")
    #expect(model.displayedRows.map(\.entry.name) == [".env"])
    model.query = "env"
    model.noteQueryChange(from: ".env")
    #expect(model.displayedRows.isEmpty, "a dot-file stays hidden until the query names the dot")
    #expect(source.stats.count == listed)

    model.query = "runs"
    model.noteQueryChange(from: "env")
    model.commitFind()
    #if os(macOS)
      try await settle(model) { model.expanded.contains("/home/ada/runs") }
    #else
      try await settle(model) { model.directory == "/home/ada/runs" }
    #endif
    #expect(source.stats.count == listed)
  }

  @Test("shell is a jump only when the browser is somewhere else")
  func shellJump() async throws {
    let host = HostProbe()
    host.workingDirectory = "/home/ada/runs"
    let model = browser(StubSource(tree), host: host)
    await model.go(to: "/home/ada/runs")
    #expect(model.shellDirectory == nil)
    model.goToShell()
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.history.isEmpty)

    await model.go(to: "/home/ada")
    #expect(model.shellDirectory == "/home/ada/runs")
    model.goToShell()
    try await settle(model) { model.directory == "/home/ada/runs" }
    #expect(model.history == ["/home/ada/runs", "/home/ada"])
  }

  @Test("find is a command, and a paste is not one typed character")
  func findCommandAndPaste() {
    let model = browser(StubSource(tree))
    let find = model.commands.first { $0.id == "find" }
    #expect(find?.symbol == "magnifyingglass")
    find?.action()
    #expect(model.finding)
    #expect(model.findTicket == 1)

    #expect(FindQuery.pasted(from: "", to: "a/b"))
    #expect(!FindQuery.pasted(from: "lab-new", to: "lab-new/"))
    #expect(FindQuery.classify("~/A.png")?.symbol == "house")
    #expect(FindQuery.classify("runs/plot.png")?.symbol == "terminal")
    #expect(FindQuery.classify("plot")?.symbol == "magnifyingglass")
  }
}

@Suite("the preview cache")
struct FileCacheTests {
  private func entry(_ path: String, size: UInt64 = 3, modified: UInt64? = 1) -> FileEntry {
    FileEntry(
      name: String(path.split(separator: "/").last!), path: path, kind: .file, size: size,
      modified: modified, permissions: 0o644)
  }

  #if os(macOS)
    @Test("previews are kept in /tmp")
    func previewsLiveInTemporary() {
      let cache = FileCache(host: UUID())
      #expect(cache.root.path.hasPrefix("/tmp/"))
    }
  #endif

  @Test("moving a copy takes it out of the cache")
  func moveTakesTheCopy() throws {
    let cache = scratchCache()
    let file = entry("/a/plot.png")
    let cached = cache.location(for: file)
    try Data("png".utf8).write(to: cached)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("files-cache-move-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent("plot.png")
    #expect(cache.move(file, to: destination))
    #expect(cache.cached(file) == nil)
    #expect(try Data(contentsOf: destination) == Data("png".utf8))
    #expect(!FileManager.default.fileExists(atPath: cached.path))
  }

  @Test("a changed file is a different copy")
  func keyedByContent() throws {
    let cache = scratchCache()
    let before = entry("/a/plot.png")
    try Data("x".utf8).write(to: cache.location(for: before))
    #expect(cache.cached(before) != nil)
    #expect(cache.cached(entry("/a/plot.png", modified: 2)) == nil)
    #expect(cache.cached(entry("/a/plot.png", size: 4)) == nil)
    #expect(cache.cached(entry("/b/plot.png")) == nil)
  }

  @Test("a hostile name stays inside the cache")
  func namesStayInside() {
    let cache = scratchCache()
    let url = cache.location(for: entry("/x/..") )
    #expect(url.lastPathComponent == "file")
    #expect(url.path.hasPrefix(cache.root.path))
  }

  @Test("trimming removes the least recently used first")
  func trimsOldest() throws {
    let cache = scratchCache()
    let old = entry("/old.bin")
    let new = entry("/new.bin")
    try Data(count: 1000).write(to: cache.location(for: old))
    try FileManager.default.setAttributes(
      [.modificationDate: Date.distantPast],
      ofItemAtPath: cache.location(for: old).deletingLastPathComponent().path)
    try Data(count: 1000).write(to: cache.location(for: new))
    cache.trim(to: 1500)
    #expect(cache.cached(old) == nil)
    #expect(cache.cached(new) != nil)
  }
}
