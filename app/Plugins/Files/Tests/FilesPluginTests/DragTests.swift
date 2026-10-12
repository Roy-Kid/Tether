#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import Tether
  import TetherPluginKit
  import UniformTypeIdentifiers

  @testable import FilesPlugin

  /// A drag as AppKit hands it to a drop target, without a pointer.
  private final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint
    weak var window: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
      self.pasteboard = pasteboard
      self.location = location
      self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
      options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
      classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
      using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    /// Asked by SwiftUI once a drop is done.
    @objc func _lastDragDestinationOperation() -> NSDragOperation { .copy }
  }

  /// The terminal's drop, as `WorkspaceView` declares it.
  private struct TerminalLikeDrop: View {
    let got: ([NSItemProvider]) -> Void
    var body: some View {
      Color.gray.frame(width: 300, height: 300)
        .onDrop(of: [DroppedPath.contentType, .fileURL], isTargeted: nil) { providers in
          got(providers)
          return true
        }
    }
  }

  /// The list's own drop, which uploads files from this machine.
  private struct UploadLikeDrop: View {
    let got: ([URL]) -> Void
    var body: some View {
      Color.gray.frame(width: 300, height: 300)
        .dropDestination(for: URL.self) { urls, _ in
          got(urls)
          return !urls.isEmpty
        }
    }
  }

  /// Every call a promise's completion handler got, from whichever thread.
  private final class Completions: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Error?] = []
    func record(_ error: Error?) { lock.withLock { calls.append(error) } }
    var all: [Error?] { lock.withLock { calls } }
  }

  @MainActor
  @Suite("dragging a file row", .serialized)
  struct DragTests {
    init() { _ = NSApplication.shared }

    private let tree: [String: FileKind] = [
      "/": .directory, "/home": .directory, "/home/ada": .directory, "/home/ada/b.txt": .file,
      "/home/ada/c.txt": .file, "/home/ada/runs": .directory,
    ]

    private func context() -> TabContext {
      TabContext(
        id: UUID(),
        plugin: PluginContext(
          connection: nil, hostLabel: "lab", hostID: UUID(),
          openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
        focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
    }

    private func browser(_ source: StubSource) async throws -> FilesTab {
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("drag-\(UUID())")
      let model = FilesTab(
        tab: context(), cache: FileCache(host: UUID(), base: base), open: { _ in source },
        present: { _ in }, defaults: cleanDefaults())
      await model.go(to: "/home/ada")
      return model
    }

    /// A folder Finder might drop into, gone after the test.
    private func dropFolder() throws -> URL {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID())")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      return folder
    }

    private func promise(_ model: FilesTab, _ path: String = "/home/ada/b.txt") throws -> FilePromise {
      FilePromise(model.fetch(try #require(model.entry(path))))
    }

    /// Asks for the write the way AppKit does: on the queue the writer names.
    private func write(_ promise: FilePromise, to url: URL, into calls: Completions) {
      let writer = promise.writer
      nonisolated(unsafe) let provider: NSFilePromiseProvider = promise
      writer.operationQueue(for: promise).addOperation {
        writer.filePromiseProvider(provider, writePromiseTo: url) { calls.record($0) }
      }
    }

    private func eventually(_ seconds: Double = 5, _ done: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Long enough for a second call to have arrived, had there been one.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    @Test("a promise writes the file off the main thread while the main actor stays free")
    func promiseWritesOffMain() async throws {
      let source = StubSource(tree)
      source.downloadDelay = .milliseconds(600)
      let model = try await browser(source)
      defer { model.close() }
      let promise = try promise(model)
      #expect(promise.writer.operationQueue(for: promise) !== OperationQueue.main)
      #expect(promise.writer.filePromiseProvider(promise, fileNameForType: promise.fileType) == "b.txt")
      let folder = try dropFolder()
      let url = folder.appendingPathComponent("b.txt")
      let calls = Completions()
      write(promise, to: url, into: calls)
      try await eventually { !source.downloadsOnMain.isEmpty }
      // The download is being held. The main actor still answers at once.
      let asked = Date()
      await MainActor.run {}
      #expect(Date().timeIntervalSince(asked) < 0.2)
      #expect(calls.all.isEmpty, "the download is still held")
      #expect(model.transfers.items.map(\.name) == ["b.txt"], "the write shows as a transfer")
      try await eventually { !calls.all.isEmpty }
      try await settle()
      #expect(calls.all.count == 1)
      #expect(calls.all.first.map { $0 == nil } == true)
      #expect(source.downloadsOnMain == [false])
      #expect(try Data(contentsOf: url) == Data("/home/ada/b.txt".utf8))
      try await eventually { model.transfers.items.isEmpty }
      #expect(model.transfers.items.isEmpty, "a finished write leaves no row")
    }

    @Test("a failed download fails the promise once and leaves a failed row")
    func downloadFails() async throws {
      let source = StubSource(tree)
      source.downloadFailure = .failed(cause: "Read failed.")
      let model = try await browser(source)
      defer { model.close() }
      let url = try dropFolder().appendingPathComponent("b.txt")
      let calls = Completions()
      write(try promise(model), to: url, into: calls)
      try await eventually { !calls.all.isEmpty }
      try await settle()
      #expect(calls.all.count == 1)
      let error = try #require(calls.all.first ?? nil)
      #expect(error.localizedDescription == "Read failed.")
      #expect(!FileManager.default.fileExists(atPath: url.path))
      try await eventually { model.transfers.items.first?.failure != nil }
      #expect(model.transfers.items.map(\.failure) == ["Read failed."])
    }

    @Test("with no file session the promise fails at once")
    func disconnected() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let entry = try #require(model.entry("/home/ada/b.txt"))
      let fetch = FileFetch(entry: entry, session: nil, cache: model.cache, transfers: model.transfers)
      let promise = FilePromise(fetch)
      let url = try dropFolder().appendingPathComponent("b.txt")
      let calls = Completions()
      let started = Date()
      write(promise, to: url, into: calls)
      try await eventually { !calls.all.isEmpty }
      #expect(Date().timeIntervalSince(started) < 1)
      try await settle()
      #expect(calls.all.count == 1)
      let error = try #require(calls.all.first ?? nil)
      #expect((error as? FileError).map { if case .disconnected = $0 { true } else { false } } == true)
      #expect(source.downloads.isEmpty)
      try await eventually { model.transfers.items.first?.failure != nil }
      #expect(model.transfers.items.first?.failure != nil)
    }

    @Test("stopping the row cancels the promise quietly and leaves nothing behind")
    func stopped() async throws {
      let source = StubSource(tree)
      source.downloadDelay = .seconds(30)
      let model = try await browser(source)
      defer { model.close() }
      let url = try dropFolder().appendingPathComponent("b.txt")
      let calls = Completions()
      write(try promise(model), to: url, into: calls)
      try await eventually { !model.transfers.items.isEmpty && !source.downloadsOnMain.isEmpty }
      let row = try #require(model.transfers.items.first)
      model.transfers.cancel(row.id)
      try await eventually(3) { !calls.all.isEmpty }
      try await settle()
      #expect(calls.all.count == 1)
      let error = try #require(calls.all.first ?? nil)
      #expect((error as? CocoaError)?.code == .userCancelled, "a stop is the person's own no")
      #expect(!FileManager.default.fileExists(atPath: url.path))
      try await eventually { model.transfers.items.isEmpty }
      #expect(model.transfers.items.isEmpty, "a stopped copy is not a failure")
    }

    @Test("a folder that cannot be written refuses before anything is fetched")
    func unwritable() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let folder = try dropFolder()
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
      let calls = Completions()
      write(try promise(model), to: folder.appendingPathComponent("b.txt"), into: calls)
      try await eventually { !calls.all.isEmpty }
      try await settle()
      #expect(calls.all.count == 1)
      let error = try #require(calls.all.first ?? nil)
      #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
      #expect(source.downloads.isEmpty)
      try await eventually { model.transfers.items.first?.failure != nil }
      #expect(model.transfers.items.first?.failure != nil)
    }

    @Test("a name already taken is never replaced")
    func taken() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let url = try dropFolder().appendingPathComponent("b.txt")
      try Data("mine".utf8).write(to: url)
      let calls = Completions()
      write(try promise(model), to: url, into: calls)
      try await eventually { !calls.all.isEmpty }
      try await settle()
      #expect(calls.all.count == 1)
      #expect(((calls.all.first ?? nil) as? CocoaError)?.code == .fileWriteFileExists)
      #expect(try Data(contentsOf: url) == Data("mine".utf8))
      #expect(source.downloads.isEmpty)
    }

    /// SwiftUI reads an item holding a promise as the promise alone, so the
    /// path the terminal pastes cannot ride on it.
    @Test("a file is a promise and nothing else; the paths travel on an item of their own")
    func pasteboardTypes() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let board = NSPasteboard(name: .init("tether-drag-types-\(UUID())"))
      defer { board.releaseGlobally() }
      let file = try #require(model.entry("/home/ada/b.txt"))
      let folder = try #require(model.entry("/home/ada/runs"))

      let promise = DraggedRow.promise(for: file, model: model)
      let types = promise.writableTypes(for: board)
      #expect(types.contains(.init("com.apple.NSFilePromiseItemMetaData")))
      #expect(types.contains(.init("com.apple.pasteboard.promised-file-content-type")))
      for type in types {
        let uti = UTType(type.rawValue)
        #expect(uti?.conforms(to: .text) != true, "\(type.rawValue) would make Finder a clipping")
        #expect(uti?.conforms(to: .url) != true, "\(type.rawValue) would hand over a URL")
      }
      #expect(promise.fileType == UTType.plainText.identifier)

      let paths = DraggedRow.paths([file, folder])
      #expect(paths.types == [.droppedPath], "a path item is no string and no file")
      #expect(paths.data(forType: .droppedPath) == Data("/home/ada/b.txt\n/home/ada/runs".utf8))

      #expect(FilePromise.fileType(for: "plot.png") == .png)
      #expect(FilePromise.fileType(for: "Makefile") == .data)
    }

    /// The probe behind the item of its own: SwiftUI's drop reads an item
    /// that holds a promise as an empty provider, whatever else it carries.
    @Test("SwiftUI's drop drops everything else on an item holding a promise")
    func promiseItemsHideTheirOtherTypes() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      var handed: [NSItemProvider]?
      let (window, target) = try await host(TerminalLikeDrop { handed = $0 })
      defer { window.orderOut(nil) }
      let board = try drop([PathCarryingPromise(model.fetch(try #require(model.entry("/home/ada/b.txt"))))],
        on: target, in: window)
      defer { board.releaseGlobally() }
      #expect(board.pasteboardItems?.first?.types.contains(.droppedPath) == true)
      #expect(handed?.count == 1)
      #expect(handed?.first?.hasItemConformingToTypeIdentifier(DroppedPath.contentType.identifier) == false)
    }

    @Test("outside this app only files can be dropped; inside, paths go to the terminal")
    func operations() {
      #expect(DraggedRow.operations(.outsideApplication, carriesFiles: false) == [])
      #expect(DraggedRow.operations(.outsideApplication, carriesFiles: true) == .copy)
      #expect(DraggedRow.operations(.withinApplication, carriesFiles: false) == [.copy, .generic])
      #expect(DraggedRow.operations(.withinApplication, carriesFiles: true) == [.copy, .generic])
    }

    @Test("a row in the selection drags the whole selection; one outside drags itself")
    func selectionIsDragged() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let b = try #require(model.entry("/home/ada/b.txt"))
      let runs = try #require(model.entry("/home/ada/runs"))
      model.selection = ["/home/ada/c.txt", "/home/ada/b.txt"]
      #expect(model.draggedEntries(b).map(\.path) == ["/home/ada/b.txt", "/home/ada/c.txt"])
      #expect(model.draggedEntries(runs).map(\.path) == ["/home/ada/runs"])
    }

    /// The drop as the terminal performs it, through SwiftUI: a promise for
    /// each file, and one item with the paths.
    @Test("files dropped on a terminal in this app are their paths, at once, and nothing is fetched")
    func dropOnTerminal() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      model.selection = ["/home/ada/b.txt", "/home/ada/c.txt"]
      var handed: [NSItemProvider]?
      let (window, target) = try await host(TerminalLikeDrop { handed = $0 })
      defer { window.orderOut(nil) }
      let started = Date()
      let board = try drop(dragged(model, from: "/home/ada/b.txt"), on: target, in: window)
      defer { board.releaseGlobally() }
      let carried = (handed ?? []).filter {
        $0.hasItemConformingToTypeIdentifier(DroppedPath.contentType.identifier)
      }
      #expect(carried.count == 1)
      let provider = try #require(carried.first)
      let path = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
        _ = provider.loadTransferable(type: DroppedPath.self) { done.resume(returning: try? $0.get().text) }
      }
      #expect(path == "/home/ada/b.txt\n/home/ada/c.txt")
      #expect(Date().timeIntervalSince(started) < 1)
      try await settle()
      #expect(source.downloadsOnMain.isEmpty, "no download was even started")
      #expect(model.transfers.items.isEmpty)
    }

    /// The list's own drop takes files from this machine. A promise is not
    /// one, so dropping a row back on the list neither fetches nor uploads.
    @Test("a file row dropped on the list's upload target fetches nothing")
    func dropOnUpload() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      var urls: [URL] = []
      let (window, target) = try await host(UploadLikeDrop { urls = $0 })
      defer { window.orderOut(nil) }
      let board = try drop(dragged(model, from: "/home/ada/b.txt"), on: target, in: window)
      defer { board.releaseGlobally() }
      try await settle()
      #expect(urls.isEmpty)
      #expect(source.downloadsOnMain.isEmpty)
      #expect(source.uploads.isEmpty)
    }

    /// The rows' drag source holds a press until it is a click or a drag,
    /// and hands every click to the list as it was. The press's next events
    /// are scripted: posting to the application's queue outside a running
    /// app stops the run loop this test runs on, and the run ends early.
    @Test("a press on a row becomes a drag only past the threshold; anything else is the list's")
    func pressesReachTheList() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let (window, content) = try await hostBrowser(model)
      defer { window.orderOut(nil) }
      let row = try #require(self.row("/home/ada/c.txt", in: content))
      let other = try #require(self.row("/home/ada/b.txt", in: content))
      let center = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)

      #expect(row.claims(try press(.leftMouseDown, at: center, in: window)))
      #expect(!other.claims(try press(.leftMouseDown, at: center, in: window)), "another row's press")
      #expect(!row.claims(try press(.leftMouseDown, at: center, in: window, flags: .control)),
        "a control click is the menu")
      #expect(!row.claims(try press(.leftMouseDown, at: center, in: window, count: 2)),
        "a double-click opens")
      model.renaming = "/home/ada/c.txt"
      #expect(!row.claims(try press(.leftMouseDown, at: center, in: window)), "a name being edited")
      model.renaming = nil

      let down = try press(.leftMouseDown, at: center, in: window)
      let up = try press(.leftMouseUp, at: center, in: window)
      let wobble = try press(.leftMouseDragged, at: NSPoint(x: center.x + 2, y: center.y), in: window)
      let far = try press(.leftMouseDragged, at: NSPoint(x: center.x + 2, y: center.y + 5), in: window)

      var click = Script(row, [up])
      #expect(!row.becomesDrag(down))
      #expect(click.taken.isEmpty, "the release stays queued for the list")
      click = Script(row, [wobble, up])
      #expect(!row.becomesDrag(down), "movement short of the threshold is still a click")
      #expect(click.taken == [.leftMouseDragged])
      let drag = Script(row, [wobble, far])
      #expect(row.becomesDrag(down))
      #expect(drag.taken == [.leftMouseDragged, .leftMouseDragged])
      #expect(source.downloadsOnMain.isEmpty, "pressing fetches nothing")
    }

    @Test("a drag is a promise per file and one item with every path, drawn with the folders")
    func draggingItems() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let (window, content) = try await hostBrowser(model)
      defer { window.orderOut(nil) }
      let row = try #require(self.row("/home/ada/b.txt", in: content))
      let b = try #require(model.entry("/home/ada/b.txt"))
      let runs = try #require(model.entry("/home/ada/runs"))

      model.selection = ["/home/ada/b.txt", "/home/ada/c.txt", "/home/ada/runs"]
      let mixed = row.draggingItems(model.draggedEntries(b), model: model)
      #expect(mixed.count == 3)
      #expect(mixed.prefix(2).allSatisfy { $0.item is FilePromise })
      let paths = try #require(mixed.last?.item as? NSPasteboardItem)
      let text = "/home/ada/b.txt\n/home/ada/c.txt\n/home/ada/runs"
      #expect(paths.data(forType: .droppedPath) == Data(text.utf8))
      #expect(drawn(mixed.last), "the folder is drawn")
      #expect(mixed.prefix(2).allSatisfy(drawn), "each file is drawn")

      model.selection = []
      let single = row.draggingItems(model.draggedEntries(b), model: model)
      #expect(single.count == 2)
      #expect(drawn(single.first))
      #expect(!drawn(single.last), "a path item with no folder is not drawn")
      let folder = row.draggingItems(model.draggedEntries(runs), model: model)
      #expect(folder.count == 1)
      #expect(folder.first?.item is NSPasteboardItem)
      #expect(source.downloadsOnMain.isEmpty)
    }

    /// Whether an item shows a picture with pixels in it.
    private func drawn(_ item: NSDraggingItem?) -> Bool {
      let image = item?.imageComponents?.first?.contents as? NSImage
      return image?.representations.isEmpty == false
    }

    private func hostBrowser(_ model: FilesTab) async throws -> (NSWindow, NSView) {
      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Browser(model: model))
      window.orderFrontRegardless()
      try await Task.sleep(for: .milliseconds(400))
      return (window, try #require(window.contentView))
    }

    private func row(_ path: String, in view: NSView) -> RowDragView? {
      if let found = view as? RowDragView, found.entry?.path == path { return found }
      return view.subviews.lazy.compactMap { row(path, in: $0) }.first
    }

    private func press(
      _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
      count: Int = 1, flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
        pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func host(_ view: some View) async throws -> (NSWindow, NSView) {
      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: view)
      window.orderFrontRegardless()
      try await Task.sleep(for: .milliseconds(300))
      return (window, try #require(dropTarget(in: window.contentView!)))
    }

    /// What dragging the row at `path` writes, as the row's drag source
    /// writes it: the files' promises, then the paths.
    private func dragged(_ model: FilesTab, from path: String) throws -> [NSPasteboardWriting] {
      let entries = model.draggedEntries(try #require(model.entry(path)))
      let promises: [NSPasteboardWriting] = entries.filter { $0.kind == .file }
        .map { DraggedRow.promise(for: $0, model: model) }
      return promises + [DraggedRow.paths(entries)]
    }

    /// Puts `writers` on a board of their own and drops them on `target`.
    /// The board is the caller's to release once it has read the drop.
    private func drop(_ writers: [NSPasteboardWriting], on target: NSView, in window: NSWindow) throws
      -> NSPasteboard
    {
      let board = NSPasteboard(name: .init("tether-drag-test-\(UUID())"))
      board.clearContents()
      #expect(board.writeObjects(writers))
      let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
      let info = FakeDrag(pasteboard: board, location: point, window: window)
      let destination: NSDraggingDestination = target
      _ = destination.draggingEntered?(info)
      _ = destination.draggingUpdated?(info)
      _ = destination.prepareForDragOperation?(info)
      _ = destination.performDragOperation?(info)
      destination.concludeDragOperation?(info)
      return board
    }

    private func dropTarget(in view: NSView) -> NSView? {
      if String(describing: type(of: view)).contains("_PlatformDraggingDestinationView") { return view }
      return view.subviews.lazy.compactMap { dropTarget(in: $0) }.first
    }
  }
#endif

#if os(macOS)
  /// A promise that also offers the path on its own item: what the drag
  /// source deliberately does not do.
  private final class PathCarryingPromise: NSFilePromiseProvider {
    let writer: FilePromiseWriter

    init(_ fetch: FileFetch) {
      writer = FilePromiseWriter(fetch)
      super.init()
      fileType = UTType.plainText.identifier
      delegate = writer
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
      super.writableTypes(for: pasteboard) + [.droppedPath]
    }

    override func writingOptions(
      forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
      type == .droppedPath ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
      if type == .droppedPath { return DroppedPath.data(for: "/home/ada/b.txt") }
      return super.pasteboardPropertyList(forType: type)
    }
  }
#endif

#if os(macOS)
  /// The events a press would see next, handed to a row in order. Records
  /// what the row took off the queue.
  @MainActor
  private final class Script {
    private var queue: [NSEvent]
    private(set) var taken: [NSEvent.EventType] = []

    init(_ row: RowDragView, _ events: [NSEvent]) {
      queue = events
      row.nextEvent = { [unowned self] take in
        guard let first = self.queue.first else { return nil }
        if take {
          self.queue.removeFirst()
          self.taken.append(first.type)
        }
        return first
      }
    }
  }
#endif
