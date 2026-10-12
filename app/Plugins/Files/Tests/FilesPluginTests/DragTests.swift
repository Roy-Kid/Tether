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
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link, .move] }
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

  /// What SwiftUI's drag source does when a drop asks for the file URL:
  /// it loads the item's file on the thread that asked — the main thread —
  /// and waits. The wait here gives up, so a deadlock fails the test rather
  /// than hanging the run (in the app it waited forever).
  private final class SynchronousFileURL: NSObject, NSPasteboardItemDataProvider {
    let provider: NSItemProvider
    let patience: TimeInterval
    private(set) var asked = 0
    private(set) var timedOut = false
    private(set) var resolved: URL?

    init(_ provider: NSItemProvider, patience: TimeInterval) {
      self.provider = provider
      self.patience = patience
    }

    func pasteboard(
      _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
      asked += 1
      let done = DispatchSemaphore(value: 0)
      let box = Box()
      _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
        // The copy is gone once this returns; keep where it was.
        box.url = url
        done.signal()
      }
      if done.wait(timeout: .now() + patience) == .timedOut {
        timedOut = true
        return
      }
      resolved = box.url
      if let url = box.url { item.setData(url.dataRepresentation, forType: type) }
    }

    private final class Box: @unchecked Sendable { var url: URL? }
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

  @MainActor
  @Suite("dragging a file row", .serialized)
  struct DragTests {
    init() { _ = NSApplication.shared }

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

    private func browser(_ source: StubSource) async throws -> FilesTab {
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("drag-\(UUID())")
      let model = FilesTab(
        tab: context(), cache: FileCache(host: UUID(), base: base), open: { _ in source },
        present: { _ in }, defaults: cleanDefaults())
      await model.go(to: "/home/ada")
      return model
    }

    private func dragged(_ model: FilesTab, insideThisApp: Bool) throws -> NSItemProvider {
      let entry = try #require(model.entry("/home/ada/b.txt"))
      let item = DraggedFile(text: model.draggedPathText(entry), file: model.fetch(entry, insideThisApp: { insideThisApp }))
      let provider = NSItemProvider()
      provider.register(item)
      return provider
    }

    /// The hang: the drop asks for the file on the main thread and waits,
    /// and the export needed the main thread to fetch it.
    @Test("a file row's bytes arrive while the main thread waits for them")
    func exportDoesNotNeedTheMainThread() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let provider = try dragged(model, insideThisApp: false)
      #expect(provider.registeredTypeIdentifiers.contains(UTType.data.identifier))
      let waiter = SynchronousFileURL(provider, patience: 5)
      let item = NSPasteboardItem()
      waiter.pasteboard(nil, item: item, provideDataForType: .fileURL)
      #expect(!waiter.timedOut, "the export waited for the main thread that was waiting for it")
      #expect(waiter.resolved?.lastPathComponent == "b.txt")
      #expect(source.downloads.count == 1)
    }

    /// Dropped inside this app a file row means its path. Fetching it would
    /// stall the window for the length of a download and hand the terminal
    /// a copy it would send straight back.
    @Test("dropped in this app, a file row is its path and nothing is fetched")
    func insideThisAppIsThePath() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let provider = try dragged(model, insideThisApp: true)
      let started = Date()
      let waiter = SynchronousFileURL(provider, patience: 5)
      waiter.pasteboard(nil, item: NSPasteboardItem(), provideDataForType: .fileURL)
      #expect(!waiter.timedOut)
      #expect(waiter.resolved == nil)
      #expect(Date().timeIntervalSince(started) < 1)
      #expect(source.downloads.isEmpty)
      let path = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
        _ = provider.loadTransferable(type: DroppedPath.self) { done.resume(returning: try? $0.get().text) }
      }
      #expect(path == "/home/ada/b.txt")
    }

    /// The drop as the terminal performs it, through SwiftUI. SwiftUI reads
    /// the file URL before the handler runs, whatever types the target
    /// asked for, on the main thread.
    @Test("a file row dropped on a terminal in this app neither hangs nor downloads")
    func dropOnTerminal() async throws {
      let source = StubSource(tree)
      let model = try await browser(source)
      defer { model.close() }
      let provider = try dragged(model, insideThisApp: true)
      var handed: [NSItemProvider]?
      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: TerminalLikeDrop { handed = $0 })
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .milliseconds(300))
      let target = try #require(dropTarget(in: window.contentView!))
      let board = NSPasteboard(name: .init("tether-drag-test-\(UUID())"))
      defer { board.releaseGlobally() }
      board.clearContents()
      let item = NSPasteboardItem()
      item.setData(DroppedPath.data(for: "/home/ada/b.txt"), forType: .init(DroppedPath.contentType.identifier))
      let waiter = SynchronousFileURL(provider, patience: 5)
      item.setDataProvider(waiter, forTypes: [.fileURL])
      #expect(board.writeObjects([item]))
      let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
      let info = FakeDrag(pasteboard: board, location: point, window: window)
      let destination = try #require(target as? NSDraggingDestination)
      _ = destination.draggingEntered?(info)
      _ = destination.draggingUpdated?(info)
      _ = destination.prepareForDragOperation?(info)
      #expect(destination.performDragOperation?(info) == true)
      destination.concludeDragOperation?(info)
      #expect(waiter.asked >= 1, "SwiftUI asks for the file URL at the drop")
      #expect(!waiter.timedOut, "the main thread waited on an export that needed it")
      #expect(source.downloads.isEmpty)
      #expect(handed?.count == 1)
    }

    /// The pointer is not moved: a speck of a window is kept under it,
    /// wherever the person using this Mac moves it, then taken away.
    @Test("a drop over this app's own window is inside this app")
    func dropSite() async throws {
      let screen = try #require(NSScreen.screens.first)
      let speck = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 8, height: 8),
        styleMask: [.borderless], backing: .buffered, defer: false)
      speck.alphaValue = 0.02
      speck.ignoresMouseEvents = true
      speck.level = .floating
      // On whatever Space is showing, including someone's full-screen one.
      speck.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      func underPointer() {
        guard let pointer = CGEvent(source: nil)?.location else { return }
        // Window server coordinates start top left; AppKit's bottom left.
        speck.setFrameOrigin(NSPoint(x: pointer.x - 4, y: screen.frame.maxY - pointer.y - 4))
      }
      underPointer()
      speck.orderFrontRegardless()
      var over = false
      for _ in 0..<100 where !over {
        try await Task.sleep(for: .milliseconds(20))
        underPointer()
        try await Task.sleep(for: .milliseconds(20))
        over = DropSite.isThisApp()
      }
      speck.orderOut(nil)
      var gone = false
      for _ in 0..<100 where !gone {
        try await Task.sleep(for: .milliseconds(20))
        gone = !DropSite.isThisApp()
      }
      #expect(over)
      #expect(gone, "nothing of this process is under the pointer once it is gone")
    }

    private func dropTarget(in view: NSView) -> NSView? {
      if String(describing: type(of: view)).contains("_PlatformDraggingDestinationView") { return view }
      return view.subviews.lazy.compactMap { dropTarget(in: $0) }.first
    }
  }
#endif
