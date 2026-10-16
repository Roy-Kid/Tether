#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import Tether
  import TetherPluginKit

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

  /// Files dragged in from Finder.
  ///
  /// SwiftUI's list registers its rows' drop types on the table itself once
  /// the rows are redrawn, and the table sits in front of a drop declared on
  /// the list. AppKit then hands every file the table, which only knows the
  /// drops its rows and their `ForEach` declare.
  @MainActor
  @Suite("dropping files from Finder on the list", .serialized)
  struct UploadDropTests {
    init() { _ = NSApplication.shared }

    private let tree: [String: FileKind] = [
      "/": .directory, "/home": .directory, "/home/ada": .directory, "/home/ada/b.txt": .file,
      "/home/ada/runs": .directory,
    ]

    private func browser(_ source: StubSource) async throws -> FilesTab {
      let context = TabContext(
        id: UUID(),
        plugin: PluginContext(
          connection: nil, hostLabel: "lab", hostID: UUID(),
          openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
        focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID())")
      let model = FilesTab(
        tab: context, cache: FileCache(host: UUID(), base: base), open: { _ in source },
        present: { _ in }, defaults: cleanDefaults())
      await model.go(to: "/home/ada")
      return model
    }

    /// The real list, moved away and back so the table has redrawn its rows.
    private func host(_ model: FilesTab) async throws -> (NSWindow, NSTableView) {
      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      let root = NSHostingView(rootView: Browser(model: model))
      window.contentView = root
      window.orderFrontRegardless()
      try await Task.sleep(for: .milliseconds(300))
      await model.go(to: "/home")
      try await Task.sleep(for: .milliseconds(200))
      await model.go(to: "/home/ada")
      try await Task.sleep(for: .milliseconds(300))
      return (window, try #require(table(in: root)))
    }

    private func table(in view: NSView) -> NSTableView? {
      if let found = view as? NSTableView { return found }
      return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    /// Drops `writers` on `target` at `point`, in its window's coordinates.
    private func drop(
      _ writers: [NSPasteboardWriting], on target: NSView, at point: NSPoint, in window: NSWindow
    ) -> Bool {
      let board = NSPasteboard(name: .init("tether-upload-drop-\(UUID())"))
      defer { board.releaseGlobally() }
      board.clearContents()
      board.writeObjects(writers)
      let info = FakeDrag(pasteboard: board, location: point, window: window)
      let destination: NSDraggingDestination = target
      guard destination.draggingEntered?(info) != [] else { return false }
      _ = destination.draggingUpdated?(info)
      _ = destination.prepareForDragOperation?(info)
      let done = destination.performDragOperation?(info) ?? false
      destination.concludeDragOperation?(info)
      return done
    }

    private func localFile() throws -> URL {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("finder-\(UUID()).txt")
      try Data("from finder".utf8).write(to: file)
      return file
    }

    private func eventually(_ done: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(5)
      while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("the table registers file drops, and a file dropped on it lands in the folder shown")
    func dropOnTable() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let (window, table) = try await host(model)
      defer { window.orderOut(nil) }
      #expect(table.registeredDraggedTypes.contains(.fileURL), "the table is what AppKit picks")

      let fileRow = try #require(model.displayedRows.firstIndex { $0.entry.path == "/home/ada/b.txt" })
      let row = table.rect(ofRow: fileRow)
      let points = [
        table.convert(NSPoint(x: row.midX, y: row.midY), to: nil),
        table.convert(NSPoint(x: table.bounds.midX, y: table.bounds.maxY - 4), to: nil),
      ]
      for point in points {
        let file = try localFile()
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(drop([file as NSURL], on: table, at: point, in: window))
        try await eventually { source.uploads.contains { $0.1 == "/home/ada/\(file.lastPathComponent)" } }
        #expect(source.uploads.last?.0 == file.path)
        #expect(source.uploads.last?.1 == "/home/ada/\(file.lastPathComponent)")
      }
    }

    @Test("a row dragged back onto the table is not a file from this machine")
    func ownRowFetchesNothing() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let (window, table) = try await host(model)
      defer { window.orderOut(nil) }
      let entry = try #require(model.entry("/home/ada/b.txt"))
      let point = table.convert(NSPoint(x: table.bounds.midX, y: table.bounds.maxY - 4), to: nil)
      _ = drop(
        [DraggedRow.promise(for: entry, model: model), DraggedRow.paths([entry])],
        on: table, at: point, in: window)
      try await Task.sleep(for: .milliseconds(300))
      #expect(source.downloads.isEmpty)
      #expect(source.uploads.isEmpty)
    }
  }
#endif
