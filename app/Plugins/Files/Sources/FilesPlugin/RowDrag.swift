#if os(macOS)
  import AppKit
  import SwiftUI
  import Tether
  import TetherUI

  /// Where a row's drag starts on a Mac: an AppKit drag of file promises.
  ///
  /// SwiftUI's own drag hands a receiver the file as a URL, and fetches it on
  /// the main thread while the receiver waits: the window froze for the whole
  /// download. A promise is fetched after the drop, on a queue of its own.
  ///
  /// Behind the row and never hit, so a click, a double-click and a right
  /// click reach the list as before. A press on the row is held until the
  /// pointer moves far enough to be a drag, which starts one, or the button
  /// comes up, which hands the press to the list as it was.
  struct RowDragSource: NSViewRepresentable {
    let model: FilesTab
    let entry: FileEntry

    func makeNSView(context: Context) -> RowDragView {
      let view = RowDragView()
      view.model = model
      view.entry = entry
      return view
    }

    func updateNSView(_ view: RowDragView, context: Context) {
      view.model = model
      view.entry = entry
    }

    static func dismantleNSView(_ view: RowDragView, coordinator: ()) { view.stop() }
  }

  final class RowDragView: NSView, NSDraggingSource {
    weak var model: FilesTab?
    var entry: FileEntry?
    /// Whether the drag in flight carries a file, which is all a drop
    /// outside this app can take.
    private var carriesFiles = false

    /// How far the pointer travels before a press is a drag. AppKit has no
    /// public value; its tables start about here.
    static let threshold: CGFloat = 4

    /// Rows painted on the drag. The rest are still dragged; drawing every
    /// selected row before the drag moved froze a large selection.
    static let drawnRows = 8

    /// The press's next movement or release, left where it is unless taken.
    /// The application's queue; a test hands its own, since posting to that
    /// queue outside a running app stops the run loop the test is on.
    var nextEvent: (_ take: Bool) -> NSEvent? = { take in
      NSApp.nextEvent(
        matching: [.leftMouseDragged, .leftMouseUp],
        until: take ? .distantPast : Date(timeIntervalSinceNow: 0.1),
        inMode: .eventTracking, dequeue: take)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The row under this press. The list has one monitor; each row used to
    /// have its own, so a click walked every row that had ever been shown.
    static func under(_ event: NSEvent) -> RowDragView? {
      guard let content = event.window?.contentView,
        let hit = content.hitTest(event.locationInWindow)
      else { return nil }
      var current: NSView? = hit
      while let view = current, !(view is NSTableView) {
        if let row = find(in: view, event: event) { return row }
        current = view.superview
      }
      return nil
    }

    private static func find(in view: NSView, event: NSEvent) -> RowDragView? {
      if let row = view as? RowDragView,
        row.visibleRect.contains(row.convert(event.locationInWindow, from: nil))
      {
        return row
      }
      for subview in view.subviews {
        if let row = find(in: subview, event: event) { return row }
      }
      return nil
    }

    /// A drag consumes the press. A click is left for the list, which is
    /// what extends the selection.
    func consumePress(_ event: NSEvent) -> Bool {
      guard claims(event), becomesDrag(event) else { return false }
      beginDrag(from: event)
      return true
    }

    /// The press is watched once for the list, not once for this row.
    func stop() {}

    /// A first press on this row, where the list can see it. Not a control
    /// click, which is the menu, and not one on a name being edited. Not a
    /// shift or ⌘ press either: that is a selection, and holding it to see
    /// whether it drags kept every one waiting until the button came up.
    func claims(_ event: NSEvent) -> Bool {
      guard let window, event.window === window, event.clickCount == 1,
        event.modifierFlags.isDisjoint(with: [.control, .shift, .command]),
        let model, let entry, model.renaming != entry.path,
        visibleRect.contains(convert(event.locationInWindow, from: nil))
      else { return false }
      let hit = window.contentView?.hitTest(event.locationInWindow)
      if hit is NSText || hit is NSTextField { return false }
      // Anything drawn over the list keeps its own press.
      guard let table = Self.table(holding: self) else { return false }
      return Self.table(holding: hit) === table
    }

    /// Holds the press until it is a drag or a click. Movement short of the
    /// threshold is taken off the queue; a release is left there for the
    /// list, behind the press it ends.
    func becomesDrag(_ down: NSEvent) -> Bool {
      let start = down.locationInWindow
      while true {
        guard let next = nextEvent(false) else {
          // Nothing yet: still held, or let go where this window never heard.
          if NSEvent.pressedMouseButtons & 1 == 0 { return false }
          continue
        }
        if next.type == .leftMouseUp { return false }
        _ = nextEvent(true)
        let moved = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
        if moved >= Self.threshold { return true }
      }
    }

    /// Every selected row when this one is among them, as Finder does;
    /// otherwise this row alone.
    private func beginDrag(from down: NSEvent) {
      guard let model, let entry else { return }
      let entries = model.draggedEntries(entry)
      carriesFiles = entries.contains { $0.kind == .file }
      let items = draggingItems(entries, model: model)
      let session = beginDraggingSession(with: items, event: down, source: self)
      session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// One item a row, in the order dragged, drawn as that row: a file is a
    /// promise carrying its path, a folder its path alone. The drag's count
    /// is the rows dragged.
    func draggingItems(_ entries: [FileEntry], model: FilesTab) -> [NSDraggingItem] {
      let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return entries.enumerated().map { index, entry in
        let writer: NSPasteboardWriting =
          entry.kind == .file ? DraggedRow.promise(for: entry, model: model) : DraggedRow.path(of: entry)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(
          rows(from: index, count: 1),
          contents: index < Self.drawnRows ? Self.image(of: [entry], dark: dark, row: bounds.size) : nil)
        return item
      }
    }

    /// Where `count` rows starting `index` rows below this one would be.
    private func rows(from index: Int, count: Int) -> NSRect {
      let height = bounds.height
      let y = isFlipped
        ? bounds.minY + CGFloat(index) * height
        : bounds.maxY - CGFloat(index + count) * height
      return NSRect(x: bounds.minX, y: y, width: bounds.width, height: CGFloat(count) * height)
    }

    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      DraggedRow.operations(context, carriesFiles: carriesFiles)
    }

    /// Rows as they look, one under another: a symbol and a name each.
    private static func image(of entries: [FileEntry], dark: Bool, row: NSSize) -> NSImage? {
      let rows = VStack(spacing: 0) {
        ForEach(entries, id: \.path) { entry in
          HStack(spacing: UIStyle.Space.inline) {
            Image(systemName: Names.symbol(for: entry.name, kind: entry.kind))
              .font(UIStyle.symbol)
              .foregroundStyle(entry.kind == .directory ? Theme.accent : Theme.subtle)
              .frame(width: UIStyle.Mark.glyph)
            Text(Names.display(entry.name))
              .font(UIStyle.title)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .frame(width: row.width, height: row.height, alignment: .leading)
        }
      }
      .environment(\.colorScheme, dark ? .dark : .light)
      let renderer = ImageRenderer(content: rows)
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      renderer.scale = scale
      guard let pixels = renderer.cgImage else { return nil }
      let size = NSSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale)
      return NSImage(cgImage: pixels, size: size)
    }

    private static func table(holding view: NSView?) -> NSTableView? {
      var current = view
      while let found = current {
        if let table = found as? NSTableView { return table }
        current = found.superview
      }
      return nil
    }
  }
#endif
