import Foundation
import Testing
import Tether
import TetherPluginKit

@testable import FilesPlugin

@MainActor
@Suite("the tree")
struct TreeTests {
  let tree: [String: FileKind] = [
    "/": .directory, "/home": .directory, "/home/ada": .directory,
    "/home/ada/src": .directory, "/home/ada/src/main.rs": .file, "/home/ada/src/.cache": .file,
    "/home/ada/src/deep": .directory, "/home/ada/src/deep/x.png": .file,
    "/home/ada/notes.md": .file,
  ]

  private func model(_ source: StubSource) -> FilesTab {
    FilesTab(
      tab: TabContext(
        id: UUID(),
        plugin: PluginContext(
          connection: nil, hostLabel: "lab", hostID: UUID(),
          openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
        focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {}),
      cache: FileCache(
        host: UUID(),
        base: FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID())")),
      open: { _ in source }, present: { _ in }, defaults: cleanDefaults())
  }

  private func shape(_ model: FilesTab) -> [String] {
    model.rows.map { String(repeating: "  ", count: $0.depth) + $0.entry.name }
  }

  @Test("a folder opens in place, one level deeper, and closes again")
  func expandAndCollapse() async {
    let model = model(StubSource(tree))
    await model.go(to: "/home/ada")
    #expect(shape(model) == ["src", "notes.md"])

    await model.expand(model.entry("/home/ada/src")!)
    #expect(shape(model) == ["src", "  deep", "  main.rs", "notes.md"], "dot-files stay hidden")
    await model.expand(model.entry("/home/ada/src/deep")!)
    #expect(shape(model) == ["src", "  deep", "    x.png", "  main.rs", "notes.md"])

    model.collapse(model.entry("/home/ada/src")!)
    #expect(shape(model) == ["src", "notes.md"])
    #expect(!model.expanded.contains("/home/ada/src/deep"), "what was open inside closes too")
  }

  @Test("→ opens a folder, then steps into it; ← steps out, then closes it")
  func arrows() async throws {
    let model = model(StubSource(tree))
    await model.go(to: "/home/ada")
    model.selection = ["/home/ada/src"]
    model.expandOrDescend()
    for _ in 0..<100 where model.listings["/home/ada/src"] == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.expanded.contains("/home/ada/src"))
    model.expandOrDescend()
    #expect(model.selection == ["/home/ada/src/deep"])
    model.collapseOrAscend()
    #expect(model.selection == ["/home/ada/src"])
    model.collapseOrAscend()
    #expect(!model.expanded.contains("/home/ada/src"))
  }

  @Test("a new folder goes into the selected folder, which opens to show it")
  func newFolderInSelection() async throws {
    let source = StubSource(tree)
    let model = model(source)
    await model.go(to: "/home/ada")
    await model.expand(model.entry("/home/ada/src")!)
    model.selection = ["/home/ada/src/main.rs"]
    #expect(model.targetDirectory == "/home/ada/src", "beside a selected file")
    model.selection = []
    #expect(model.targetDirectory == "/home/ada", "the root, with nothing chosen")
    model.collapse(model.entry("/home/ada/src")!)
    model.selection = ["/home/ada/src"]
    model.newFolder()
    for _ in 0..<100 where model.renaming == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(source.has("/home/ada/src/untitled folder"))
    #expect(model.renaming == "/home/ada/src/untitled folder")
    #expect(shape(model).contains("  untitled folder"))
  }

  @Test("renaming inside an open folder keeps the tree as it was")
  func renameKeepsTheTree() async {
    let model = model(StubSource(tree))
    await model.go(to: "/home/ada")
    await model.expand(model.entry("/home/ada/src")!)
    await model.rename(model.entry("/home/ada/src/main.rs")!, to: "lib.rs")
    #expect(shape(model) == ["src", "  deep", "  lib.rs", "notes.md"])
    #expect(model.selection == ["/home/ada/src/lib.rs"])
  }

  @Test("refreshing lists the open folders again, and keeps them open")
  func refreshKeepsOpenFolders() async throws {
    let source = StubSource(tree)
    let model = model(source)
    await model.go(to: "/home/ada")
    await model.expand(model.entry("/home/ada/src")!)
    try await source.makeDirectory("/home/ada/src/new")
    model.refresh()
    for _ in 0..<100 where !shape(model).contains("  new") {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(shape(model) == ["src", "  deep", "  new", "  main.rs", "notes.md"])
  }

  @Test("showing a file deep under the root opens the folders on the way")
  func showOpensTheWay() async {
    let model = model(StubSource(tree))
    await model.go(to: "/home/ada")
    let file = FileEntry(
      name: "x.png", path: "/home/ada/src/deep/x.png", kind: .file, size: 3, modified: nil,
      permissions: 0o644)
    await model.show(file)
    #expect(model.directory == "/home/ada", "the root stays")
    #expect(model.selection == ["/home/ada/src/deep/x.png"])
    #expect(shape(model).contains("    x.png"))

    await model.show(FileEntry(
      name: "home", path: "/home", kind: .directory, size: 0, modified: nil, permissions: 0))
    #expect(model.directory == "/", "outside the root, the root moves")
  }

  @Test("deleting a folder closes it and everything open inside")
  func deleteForgets() async {
    let model = model(StubSource(tree))
    await model.go(to: "/home/ada")
    await model.expand(model.entry("/home/ada/src")!)
    await model.expand(model.entry("/home/ada/src/deep")!)
    model.requestDelete([model.entry("/home/ada/src")!])
    await model.confirmDelete()
    #expect(shape(model) == ["notes.md"])
    #expect(model.expanded.isEmpty)
  }
  @Test("a collapsed folder discards an in-flight listing")
  func collapseDuringListing() async throws {
    let source = StubSource(tree)
    source.listDelay["/home/ada/src"] = .milliseconds(80)
    let model = model(source)
    await model.go(to: "/home/ada")
    let folder = try #require(model.entry("/home/ada/src"))
    let pending = Task { await model.expand(folder) }
    while !model.opening.contains(folder.path) { await Task.yield() }
    model.collapse(folder)
    await pending.value
    #expect(model.listings[folder.path] == nil)
    #expect(model.opening.isEmpty)
    #expect(!model.expanded.contains(folder.path))
  }

  @Test("an older expansion cannot clear the loading state of a reopened folder")
  func reopenDuringListing() async throws {
    let source = StubSource(tree)
    source.listDelay["/home/ada/src"] = .milliseconds(80)
    let model = model(source)
    await model.go(to: "/home/ada")
    let folder = try #require(model.entry("/home/ada/src"))
    let first = Task { await model.expand(folder) }
    while !model.opening.contains(folder.path) { await Task.yield() }
    model.collapse(folder)
    let second = Task { await model.expand(folder) }
    while !model.opening.contains(folder.path) { await Task.yield() }
    await first.value
    await second.value
    #expect(model.listings[folder.path]?.contains { $0.name == "main.rs" } == true)
    #expect(model.expanded.contains(folder.path))
    #expect(model.opening.isEmpty)
  }

  @Test("closing the browser discards pending folder results")
  func closeDuringListing() async throws {
    let source = StubSource(tree)
    source.listDelay["/home/ada/src"] = .milliseconds(80)
    let model = model(source)
    await model.go(to: "/home/ada")
    let folder = try #require(model.entry("/home/ada/src"))
    let pending = Task { await model.expand(folder) }
    while !model.opening.contains(folder.path) { await Task.yield() }
    model.close()
    await pending.value
    #expect(model.listings[folder.path] == nil)
    #expect(model.opening.isEmpty)
  }

  @Test("repeated expansion shares one pending listing")
  func repeatedExpansion() async throws {
    let source = StubSource(tree)
    source.listDelay["/home/ada/src"] = .milliseconds(80)
    let model = model(source)
    await model.go(to: "/home/ada")
    let folder = try #require(model.entry("/home/ada/src"))
    let pending = Task { await model.expand(folder) }
    while !model.opening.contains(folder.path) { await Task.yield() }
    await model.expand(folder)
    await pending.value
    #expect(source.lists.filter { $0 == folder.path }.count == 1)
    #expect(model.listings[folder.path] != nil)
  }

}
