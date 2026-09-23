#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import Tether
  import TetherPluginKit

  @testable import FilesPlugin

  /// The browser as it is drawn, in a window, answering real key events —
  /// what a person pressing space in the inspector actually exercises.
  @MainActor
  @Suite("keys in the browser")
  struct BrowserKeyTests {
    private func context() -> TabContext {
      TabContext(
        id: UUID(),
        plugin: PluginContext(
          connection: nil, hostLabel: "lab", hostID: UUID(),
          openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
        focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
      if let hit = view as? T { return hit }
      for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
      return nil
    }

    private func press(_ characters: String, code: UInt16, in window: NSWindow) {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
      window.sendEvent(event)
    }

    @Test("space on a selected file opens it in Quick Look")
    func spacePreviews() async throws {
      let source = StubSource([
        "/": .directory, "/home": .directory, "/home/ada": .directory,
        "/home/ada/plot.png": .file, "/home/ada/notes.md": .file,
      ])
      var shown: [[URL]] = []
      let model = FilesTab(
        tab: context(),
        cache: FileCache(
          host: UUID(),
          base: FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID())")),
        open: { _ in source }, present: { shown.append($0) })
      await model.go(to: "/home/ada")

      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.orderFrontRegardless()
      try await Task.sleep(for: .milliseconds(500))

      // A synthesized click does not select in an offscreen window (the
      // same is true of a bare List), so the row is selected as the click
      // would, and the list given the keyboard as the click would.
      let table = try #require(find(NSTableView.self, in: window.contentView!))
      window.makeFirstResponder(table)
      model.selection = ["/home/ada/plot.png"]
      try await Task.sleep(for: .milliseconds(200))

      press(" ", code: 49, in: window)
      for _ in 0..<100 where shown.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
      window.orderOut(nil)

      #expect(shown.first?.map(\.lastPathComponent) == ["plot.png"])
    }
  }
#endif
