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
  var workingDirectory: String?

  func context() -> TabContext {
    TabContext(
      id: UUID(),
      plugin: PluginContext(
        connection: nil, hostLabel: "lab", hostID: UUID(),
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {},
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

@MainActor
private func browser(_ source: StubSource, host: HostProbe = HostProbe()) -> FilesTab {
  FilesTab(tab: host.context(), cache: scratchCache(), open: { _ in source }, present: { _ in })
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
  }

  @Test("a large file asks before it is fetched")
  func largeFileAsks() async {
    let model = browser(StubSource(tree))
    let huge = FileEntry(
      name: "movie.mov", path: "/home/ada/movie.mov", kind: .file,
      size: FilesTab.previewLimit, modified: nil, permissions: 0o644)
    await model.preview([huge])
    #expect(model.pendingLarge == huge)
    #expect(model.previewed.isEmpty)
  }

  @Test("closing the tab with a copy in flight says what stops, and stops it")
  func closeNoteCountsTransfers() async throws {
    let source = StubSource(tree)
    source.downloadDelay = .seconds(30)
    let model = browser(source)
    await model.go(to: "/home/ada")
    #expect(model.closeNote == nil)

    let fetching = Task { await model.preview([model.entries.first { $0.name == "A.png" }!]) }
    try await settle(model) { model.transfers.running == 1 }
    #expect(model.closeNote == "1 transfer stops.")
    // Progress arrives on a later hop to the main actor than the row does.
    try await settle(model) { model.transfers.items.first?.done == 1 }

    model.close()
    await fetching.value
    #expect(model.transfers.items.isEmpty, "a stopped copy is not a failure to show")
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

  @Test("pointing at a file shows it; at a directory, shows the browser there")
  func lookingAtALink() async {
    let source = StubSource(tree)
    let host = HostProbe()
    host.workingDirectory = "/home/ada"
    let model = browser(source, host: host)
    await model.go(to: "/home/ada")

    await model.look(at: .at("runs/plot.png", in: "/home/ada"))
    #expect(model.previewed.map(\.lastPathComponent) == ["plot.png"])
    #expect(host.shown == 0, "a file opens in Quick Look, not the browser")

    await model.look(at: .at("runs", in: "/home/ada"))
    #if os(macOS)
      // A tree: the folder opens in place, the root stays.
      #expect(model.directory == "/home/ada")
      #expect(model.expanded.contains("/home/ada/runs"))
      #expect(model.selection == ["/home/ada/runs"])
    #else
      #expect(model.directory == "/home/ada/runs")
    #endif
    #expect(host.shown == 1)

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
}

@Suite("the preview cache")
struct FileCacheTests {
  private func entry(_ path: String, size: UInt64 = 3, modified: UInt64? = 1) -> FileEntry {
    FileEntry(
      name: String(path.split(separator: "/").last!), path: path, kind: .file, size: size,
      modified: modified, permissions: 0o644)
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
