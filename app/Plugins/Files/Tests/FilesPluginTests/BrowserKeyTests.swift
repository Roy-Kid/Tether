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
      // ⌃V uploads when Finder files are copied. This test is page down,
      // so the machine's clipboard must not be one of those.
      let saved = PasteboardSnapshot()
      defer { saved.restore() }
      NSPasteboard.general.clearContents()
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

    /// The pasteboard is the user's. A test that writes it puts the previous
    /// contents back, including when the assertion fails.
    private final class PasteboardSnapshot {
      private let items: [NSPasteboardItem]

      init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
          let copy = NSPasteboardItem()
          for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
          }
          return copy
        }
      }

      func restore() {
        let board = NSPasteboard.general
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
      }
    }

    @Test("⌘V uploads a file copied from Finder")
    func commandVUploads() async throws {
      let source = StubSource([
        "/": .directory, "/home": .directory, "/home/ada": .directory,
        "/home/ada/notes.txt": .file,
      ])
      let model = FilesTab(
        tab: context(),
        cache: FileCache(
          host: UUID(),
          base: FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID())")),
        open: { _ in source }, defaults: cleanDefaults())
      await model.go(to: "/home/ada")

      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.makeKeyAndOrderFront(nil)
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .milliseconds(400))

      let table = try #require(find(NSTableView.self, in: window.contentView!))
      let local = FileManager.default.temporaryDirectory
        .appendingPathComponent("finder-\(UUID().uuidString).txt")
      try Data("copied".utf8).write(to: local)
      defer { try? FileManager.default.removeItem(at: local) }
      let saved = PasteboardSnapshot()
      defer { saved.restore() }
      let board = NSPasteboard.general
      board.clearContents()
      #expect(board.writeObjects([local as NSURL]))

      // A click below the rows must take focus away from the terminal too.
      // Giving the table focus directly would hide this routing failure.
      window.makeFirstResponder(nil)
      let scroll = try #require(table.enclosingScrollView)
      let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.maxY - 10), to: nil)
      let click = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      NSApp.sendEvent(click)
      #expect(window.firstResponder === table)

      let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "v",
        charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
      NSApp.sendEvent(event)
      for _ in 0..<100 where source.uploads.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(source.uploads.map(\.1) == ["/home/ada/\(local.lastPathComponent)"])

      let second = FileManager.default.temporaryDirectory
        .appendingPathComponent("finder-\(UUID().uuidString).txt")
      try Data("again".utf8).write(to: second)
      defer { try? FileManager.default.removeItem(at: second) }
      board.clearContents()
      #expect(board.writeObjects([second as NSURL]))
      let control = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{16}",
        charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
      NSApp.sendEvent(control)
      let uploaded = "/home/ada/\(second.lastPathComponent)"
      for _ in 0..<100 where !source.uploads.map(\.1).contains(uploaded) {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(source.uploads.map(\.1) == [
        "/home/ada/\(local.lastPathComponent)", uploaded,
      ])
    }

    @Test("Finder paste writes complete bytes through the real local SFTP backend")
    func finderPasteCopiesRealFiles() async throws {
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("real-paste-\(UUID())")
      let destination = base.appendingPathComponent("destination")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: base) }
      let session = try await TerminalSession.local()
      defer { session.close() }
      let connection = try #require(session.connection)
      let source = try await connection.files()
      let model = FilesTab(tab: context(), cache: FileCache(host: UUID(), base: base),
        open: { _ in source }, defaults: cleanDefaults())
      defer { model.close() }
      await model.go(to: destination.path)
      #expect(model.problem == nil)
      let payload = Data((0..<131_073).map { UInt8($0 % 251) })
      let local = base.appendingPathComponent("文件 with spaces.bin")
      try payload.write(to: local)
      let second = base.appendingPathComponent("second.txt")
      try Data("second file\n".utf8).write(to: second)
      let saved = PasteboardSnapshot()
      defer { saved.restore() }
      let board = NSPasteboard.general
      board.clearContents()
      #expect(board.writeObjects([local as NSURL, second as NSURL]))
      let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.makeKeyAndOrderFront(nil)
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .milliseconds(400))
      let table = try #require(find(NSTableView.self, in: window.contentView!))
      window.makeFirstResponder(nil)
      let scroll = try #require(table.enclosingScrollView)
      let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.maxY - 10), to: nil)
      NSApp.sendEvent(try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
      #expect(window.firstResponder === table)
      NSApp.sendEvent(try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "v",
        charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)))
      let copied = destination.appendingPathComponent(local.lastPathComponent)
      let copiedSecond = destination.appendingPathComponent(second.lastPathComponent)
      for _ in 0..<250 where model.entry(copiedSecond.path) == nil {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(model.problem == nil)
      #expect(model.conflicts.isEmpty)
      #expect(try Data(contentsOf: copied) == payload)
      #expect(try Data(contentsOf: copiedSecond) == Data(contentsOf: second))
      #expect(model.entry(copied.path) != nil)
      #expect(model.entry(copiedSecond.path) != nil)
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
