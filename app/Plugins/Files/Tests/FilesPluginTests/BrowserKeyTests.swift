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
  @Suite("keys in the browser", .serialized)
  struct BrowserKeyTests {
    init() { _ = NSApplication.shared }

    private func context() -> TabContext {
      TabContext(
        id: UUID(),
        plugin: PluginContext(
          connection: nil, hostLabel: "lab", hostID: UUID(),
          openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
        focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
    }

    @Test("file renaming retains an editable field at any depth in a narrow inspector", arguments: [0, 24, 80])
    func nestedRenameLayout(depth: Int) async throws {
      var tree: [String: FileKind] = ["/": .directory, "/home": .directory, "/home/ada": .directory]
      var path = "/home/ada"
      for index in 0..<depth {
        path += "/folder\(index)"
        tree[path] = .directory
      }
      path += "/notes.txt"
      tree[path] = .file
      let source = StubSource(tree)
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID())")
      let model = FilesTab(tab: context(), cache: FileCache(host: UUID(), base: base), open: { _ in source })
      defer { model.close(); try? FileManager.default.removeItem(at: base) }
      await model.go(to: "/home/ada")
      var folder = "/home/ada"
      for index in 0..<depth {
        folder += "/folder\(index)"
        await model.expand(try #require(model.entry(folder)))
      }
      let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 240, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .milliseconds(200))
      model.selection = [path]
      model.renaming = path
      for width in [240, 480, 240] {
        window.setContentSize(NSSize(width: width, height: 400))
        try await Task.sleep(for: .milliseconds(200))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let field = try #require(editableField(in: content))
        #expect(field.bounds.width >= 80)
        #expect(field.bounds.height >= 14)
        #expect(field.visibleRect.width >= 80, "the editor must stay inside the inspector")
        let rect = field.convert(field.bounds, to: content)
        #expect(rect.minX >= 0 && rect.maxX <= content.bounds.width)
      }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
      if let hit = view as? T { return hit }
      for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
      return nil
    }

    private func editableField(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field.isEditable { return field }
      return view.subviews.lazy.compactMap { editableField(in: $0) }.first
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.title == title { return button }
      for sub in view.subviews {
        if let button = findButton(titled: title, in: sub) { return button }
      }
      return nil
    }

    private func press(_ characters: String, code: UInt16, in window: NSWindow,
                       base: String? = nil, flags: NSEvent.ModifierFlags = []) {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: base ?? characters, isARepeat: false, keyCode: code)!
      window.sendEvent(event)
    }

    @Test("Control navigation moves between rows and expands or collapses folders")
    func unixNavigation() async throws {
      _ = NSApplication.shared
      let source = StubSource([
        "/": .directory, "/home": .directory, "/home/ada": .directory,
        "/home/ada/notes.txt": .file, "/home/ada/plot.png": .file,
        "/home/ada/src": .directory, "/home/ada/src/main.swift": .file,
      ])
      let model = FilesTab(tab: context(),
        cache: FileCache(host: UUID(),
          base: FileManager.default.temporaryDirectory.appendingPathComponent("unix-keys-\(UUID())")),
        open: { _ in source })
      await model.go(to: "/home/ada")
      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .milliseconds(300))
      let table = try #require(find(NSTableView.self, in: window.contentView!))
      window.makeFirstResponder(table)
      model.selection = ["/home/ada/notes.txt"]
      try await Task.sleep(for: .milliseconds(100))

      press("\u{0e}", code: 45, in: window, base: "n", flags: .control)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.selection == ["/home/ada/plot.png"])
      press("\u{10}", code: 35, in: window, base: "p", flags: .control)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.selection == ["/home/ada/notes.txt"])

      model.selection = ["/home/ada/src"]
      try await Task.sleep(for: .milliseconds(100))
      press("\u{06}", code: 3, in: window, base: "f", flags: .control)
      for _ in 0..<100 where !model.rows.contains(where: { $0.entry.path == "/home/ada/src/main.swift" }) {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(model.rows.contains { $0.entry.path == "/home/ada/src/main.swift" })
      press("\u{06}", code: 3, in: window, base: "f", flags: .control)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.selection == ["/home/ada/src/main.swift"])
      press("\u{02}", code: 11, in: window, base: "b", flags: .control)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.selection == ["/home/ada/src"])
      press("\u{02}", code: 11, in: window, base: "b", flags: .control)
      try await Task.sleep(for: .milliseconds(100))
      #expect(!model.rows.contains { $0.entry.path == "/home/ada/src/main.swift" })
      press("\u{f72b}", code: 119, in: window)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.selection == ["/home/ada/plot.png"])
      press("v", code: 9, in: window, flags: .option)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.selection == ["/home/ada/src"])
      press("\u{16}", code: 9, in: window, base: "v", flags: .control)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.selection == ["/home/ada/plot.png"])
      press("\u{0d}", code: 46, in: window, base: "m", flags: .control)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.renaming == "/home/ada/plot.png")
      let editor = try #require(window.firstResponder as? NSTextView)
      editor.setSelectedRange(NSRange(location: 2, length: 0))
      press("\u{02}", code: 11, in: window, base: "b", flags: .control)
      #expect(editor.selectedRange().location == 1)
      #expect(model.selection == ["/home/ada/plot.png"])
      press("\u{1b}", code: 53, in: window)
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.renaming == nil)
    }

    @Test("space previews a text file and Delete requests its removal")
    func spacePreviews() async throws {
      let source = StubSource([
        "/": .directory, "/home": .directory, "/home/ada": .directory,
        "/home/ada/plot.png": .file, "/home/ada/notes.txt": .file,
      ])
      var shown: [[URL]] = []
      let model = FilesTab(
        tab: context(),
        cache: FileCache(
          host: UUID(),
          base: FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID())")),
        open: { _ in source }, present: { shown.append($0) }, defaults: cleanDefaults())
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
      model.selection = ["/home/ada/notes.txt"]
      try await Task.sleep(for: .milliseconds(200))

      press(" ", code: 49, in: window)
      for _ in 0..<100 where shown.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
      #expect(shown.first?.map(\.lastPathComponent) == ["notes.txt"])
      press("\u{7f}", code: 51, in: window)
      #expect(model.pendingDeletion.map(\.path) == ["/home/ada/notes.txt"])
      // Dismiss the confirmation before hiding its host; otherwise the
      // queued dialog can become a standalone modal and block the next test.
      for _ in 0..<100 where window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
      let sheet = try #require(window.sheets.first)
      let cancel = try #require(findButton(titled: "Cancel", in: sheet.contentView!))
      cancel.performClick(nil)
      for _ in 0..<100 where !model.pendingDeletion.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
      window.orderOut(nil)
    }

    @Test("a delete request from a context menu presents confirmation")
    func contextMenuDeleteConfirms() async throws {
      let source = StubSource([
        "/": .directory, "/home": .directory, "/home/ada": .directory,
        "/home/ada/notes.txt": .file,
      ])
      let model = FilesTab(
        tab: context(),
        cache: FileCache(
          host: UUID(),
          base: FileManager.default.temporaryDirectory.appendingPathComponent("delete-\(UUID())")),
        open: { _ in source }, defaults: cleanDefaults())
      await model.go(to: "/home/ada")

      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.orderFrontRegardless()
      try await Task.sleep(for: .milliseconds(300))

      // EntryMenu's Delete action queues the selected entries; Confirmations
      // must present its alert on the browser even after the context menu closes.
      model.requestDelete([try #require(model.entry("/home/ada/notes.txt"))])
      for _ in 0..<100 where window.sheets.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
      }
      let alert = try #require(window.sheets.first)
      let delete = try #require(findButton(titled: "Delete", in: alert.contentView!))
      delete.performClick(nil)
      for _ in 0..<100 where source.removed.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
      }
      window.orderOut(nil)

      #expect(source.removed == ["/home/ada/notes.txt"])
    }

    @Test("control-f opens find only once the list has the keyboard")
    func controlFOpensFind() async throws {
      let source = StubSource([
        "/": .directory, "/home": .directory, "/home/ada": .directory,
        "/home/ada/notes.txt": .file,
      ])
      let model = FilesTab(
        tab: context(),
        cache: FileCache(
          host: UUID(),
          base: FileManager.default.temporaryDirectory.appendingPathComponent("find-\(UUID())")),
        open: { _ in source }, defaults: cleanDefaults())
      await model.go(to: "/home/ada")

      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.orderFrontRegardless()
      try await Task.sleep(for: .milliseconds(500))

      let table = try #require(find(NSTableView.self, in: window.contentView!))
      window.makeFirstResponder(table)
      try await Task.sleep(for: .milliseconds(200))

      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{06}",
        charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
      window.sendEvent(event)
      for _ in 0..<50 where !model.finding { try await Task.sleep(for: .milliseconds(20)) }
      window.orderOut(nil)
      #expect(model.finding)
    }
  }
#endif
