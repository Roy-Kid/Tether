import Foundation
import SwiftUI
import Testing
import Tether
import TetherPluginKit

@testable import FilesPlugin

/// An upload either arrives, asks, or says why not — and what it says
/// survives the listing that follows it.
@MainActor
@Suite("uploads", .serialized)
struct UploadTests {
  init() {
    #if os(macOS)
      _ = NSApplication.shared
    #endif
  }

  private let tree: [String: FileKind] = [
    "/": .directory, "/home": .directory, "/home/ada": .directory, "/home/ada/b.txt": .file,
  ]

  private func context() -> TabContext {
    TabContext(
      id: UUID(),
      plugin: PluginContext(
        connection: nil, hostLabel: "lab", hostID: UUID(),
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
  }

  private func browser(_ source: StubSource) -> FilesTab {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("uploads-\(UUID())")
    return FilesTab(
      tab: context(), cache: FileCache(host: UUID(), base: base), open: { _ in source },
      present: { _ in }, defaults: cleanDefaults())
  }

  private func scratchFile(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("upload-src-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data("payload".utf8).write(to: url)
    return url
  }

  /// A server that will not answer `lstat` for a name that is not there yet
  /// — permission on the directory, a server that reports a bare failure —
  /// still takes the file. Whether the name is free is the upload's own
  /// question, asked where it can refuse to overwrite.
  @Test("a name the server will not stat still uploads")
  func uploadDoesNotHingeOnStat() async throws {
    let source = StubSource(tree)
    source.lstatFailure = .failed(cause: "/home/ada/new.txt: Failure")
    let model = browser(source)
    defer { model.close() }
    await model.go(to: "/home/ada")
    let local = try scratchFile("new.txt")
    let arrived = await model.upload([local], into: "/home/ada")
    #expect(arrived == ["/home/ada/new.txt"])
    #expect(source.has("/home/ada/new.txt"))
    #expect(model.entry("/home/ada/new.txt") != nil)
    #expect(model.problem == nil)
  }

  /// The listing after an upload succeeds, and used to clear the one line
  /// that said the upload had failed: the person saw nothing at all.
  @Test("a failed upload still says so after the directory is listed again")
  func failureSurvivesRelist() async throws {
    let source = StubSource(tree)
    source.uploadFailure = .permissionDenied(path: "/home/ada/new.txt")
    let model = browser(source)
    defer { model.close() }
    await model.go(to: "/home/ada")
    let local = try scratchFile("new.txt")
    let arrived = await model.upload([local], into: "/home/ada")
    #expect(arrived.isEmpty)
    #expect(model.problem == FileError.permissionDenied(path: "/home/ada/new.txt").errorDescription)
    #expect(model.transfers.items.map(\.failure) == [model.problem])
  }

  /// A taken name is a question, not a failure: no failed row is left for it.
  @Test("a taken name asks, and leaves no failed transfer behind")
  func takenNameAsks() async throws {
    let source = StubSource(tree)
    let model = browser(source)
    defer { model.close() }
    await model.go(to: "/home/ada")
    let local = try scratchFile("b.txt")
    let arrived = await model.upload([local], into: "/home/ada")
    #expect(arrived.isEmpty)
    #expect(model.conflicts.map(\.target) == ["/home/ada/b.txt"])
    #expect(model.transfers.items.isEmpty)
    #expect(model.problem == nil)
    #expect(source.uploads.allSatisfy { $0.2 == false })
  }

  #if os(macOS)
    /// Answers every question the browser asks with one action.
    private final class Answering: PluginServing {
      let action: String
      var asked: [String] = []
      init(_ action: String) { self.action = action }
      func notify(title: String, body: String) async {}
      func ask(_ prompt: PluginPrompt) async -> PluginAnswer {
        asked.append(prompt.title)
        return PluginAnswer(action: action)
      }
      func storageGet(pluginID: String, pluginName: String, key: String) async throws -> String? { nil }
      func storageSet(pluginID: String, pluginName: String, key: String, value: String) async throws {}
      func readDocument(pluginID: String, handle: UUID) async throws -> Data { Data() }
      func openStream(pluginID: String, url: URL) async throws -> UUID { UUID() }
      func closeStream(pluginID: String, id: UUID) async {}
      func reportStatus(pluginID: String, item: PluginStatusBarItem) {}
    }

    /// The dialog's answer is acted on by the view that asked. Settling the
    /// question changes what the view is asking about, and the work it
    /// started must not be cancelled with it.
    @Test("Replace in the name-taken dialog replaces the file", arguments: ["replace", "keep"])
    func replaceFromDialog(answer: String) async throws {
      let services = Answering(answer)
      PluginGateway.current = services
      defer { PluginGateway.current = nil }
      let source = StubSource(tree)
      let model = browser(source)
      defer { model.close() }
      await model.go(to: "/home/ada")
      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .milliseconds(200))
      let local = try scratchFile("b.txt")
      await model.upload([local], into: "/home/ada")
      for _ in 0..<200 where source.uploads.isEmpty || !model.conflicts.isEmpty || !model.transfers.items.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(services.asked == ["Replace “b.txt”?"])
      #expect(model.conflicts.isEmpty)
      if answer == "replace" {
        #expect(source.uploads.map(\.1) == ["/home/ada/b.txt"])
        #expect(source.uploads.map(\.2) == [true])
      } else {
        #expect(source.uploads.map(\.1) == ["/home/ada/b 2.txt"])
        #expect(source.uploads.map(\.2) == [false])
      }
      #expect(model.transfers.items.isEmpty)
    }
  #endif
}
