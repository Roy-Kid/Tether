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

}
