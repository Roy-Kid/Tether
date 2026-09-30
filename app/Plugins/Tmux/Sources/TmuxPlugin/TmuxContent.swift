import SwiftUI
import Tether
import TetherUI

#if os(macOS)
  import AppKit
#endif

/// Plugin-local visual roles: this package never imports the app's theme.
private enum TmuxStyle {
  static let inset: CGFloat = 12
  static let markerRadius: CGFloat = 2
  static let markerWidth: CGFloat = 18
  static let markerHeight: CGFloat = 3
  static let markerInset: CGFloat = 4
  static let dividerWidth: CGFloat = 5
  static let warning = Color.orange
  #if os(macOS)
    static let controlSize: CGFloat = 22
  #else
    static let controlSize: CGFloat = 44
  #endif
}

struct TmuxContent: View {
  @Bindable var model: TmuxTab
  @AppStorage("terminalFontSize") private var fontSize = 13.0
  var body: some View {
    VStack(spacing: 0) {
      if let error = model.error {
        HStack(alignment: .top) {
          Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(
            .enabled)
          Spacer()
          Button {
            model.error = nil
          } label: {
            Image(systemName: "xmark")
              .font(.caption.weight(.semibold))
              .frame(width: TmuxStyle.controlSize, height: TmuxStyle.controlSize)
              .contentShape(Rectangle())
          }.buttonStyle(.borderless).accessibilityLabel("Dismiss error")
            .help("Dismiss error")
        }
        .padding(TmuxStyle.inset)
        .background(.background)
        .overlay(alignment: .leading) {
          Rectangle().fill(TmuxStyle.warning).frame(width: TmuxStyle.markerHeight)
        }
      }
      if model.session == nil {
        ContentUnavailableView("Original shell", systemImage: "terminal")
      } else {
        if let ending = model.snapshot?.ended {
          HStack {
            Label(ending, systemImage: "wifi.slash").font(.callout)
            Spacer()
            Button("Reconnect") { model.reconnect() }.disabled(model.busy)
          }.padding(TmuxStyle.inset).background(.background)
            .overlay(alignment: .bottom) { Divider() }
        }
        if let window = model.currentWindow {
          panes(window).allowsHitTesting(!model.ended)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .dialog(for: model.pendingDestruction) { action in
      Dialog.confirm(
        endTitle(action), verb: "End", role: .destructive, cancel: { model.pendingDestruction = nil }
      ) {
        model.pendingDestruction = nil
        model.perform(action)
      }
    }
    .task(id: model.isShowing ? model.session?.id : nil) {
      await model.followShellClient()
    }
  }

  /// A pane's history is scrolled by lines. The ends are as many lines as
  /// there could be: the engine stops at either one.
  static func lines(for scroll: ScrollTo, page: Int32) -> Int32 {
    switch scroll {
    case .lines(let count): count
    case .pageUp: max(page - 1, 1)
    case .pageDown: -max(page - 1, 1)
    case .oldest: Int32(Int16.max)
    case .live: -Int32(Int16.max)
    }
  }

  private func endTitle(_ action: TmuxAction) -> String {
    switch action {
    case .closeWindow(id: _): "End this window?"
    case .closePane(id: _): "End this pane?"
    default: "End this?"
    }
  }

  private func panes(_ window: TmuxWindowInfo) -> some View {
    let asked = min(24, max(10, fontSize))
    let full = FontMetrics(size: asked)
    return GeometryReader { geometry in
      // Two sizes, and the difference matters. `full` is the type the person
      // asked for, and it decides what to ask tmux for. `metrics` is what
      // the window costs to draw *now* — another client can hold the window
      // wider than this screen, and shrinking the type shows the whole grid
      // instead of its top-left corner.
      let metrics = fitting(window, in: geometry.size, asked: asked, at: full)
      // Same cells the surface draws. Stretching to the view (pixels / tmux
      // cells) and then drawing at cellWidth is how a slightly-too-wide
      // window painted past the clip.
      let cell = metrics.cellWidth
      let line = metrics.lineHeight
      let visible = model.snapshot?.panes.filter { $0.window == window.id && $0.visible } ?? []
      let boxes = visible.map { PaneBox(id: $0.id, x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
      let placed = Self.pieces(
        panes: boxes, windowColumns: Int(window.width), windowRows: Int(window.height),
        cell: cell, line: line, divider: TmuxStyle.dividerWidth)
      // The grid is the top of the surface. Spare room under it stays in
      // the same view, or the last row is the clip edge and its glyphs are cut.
      let pieces = placed.map { piece -> PanePiece in
        guard case .pane(let id) = piece.kind,
          let pane = visible.first(where: { $0.id == id }),
          let box = boxes.first(where: { $0.id == id })
        else { return piece }
        var expanded = piece
        expanded.frame = Self.surfaceFrame(
          pane: box, columns: Int(pane.frame.columns), rows: Int(pane.frame.rows),
          among: boxes, cell: cell, line: line, view: geometry.size)
        return expanded
      }
      // Placed, not positioned. `position` keeps each pane's hit target as
      // the whole window and only draws the grid somewhere inside it, so a
      // wheel or a drag landed on a divider — or on another pane's empty
      // area — and the terminal under the pointer never saw it. Typing still
      // worked, because keys follow the first responder.
      // The surface is given `metrics`. Measuring the setting's size again
      // draws a larger grid than this frame, and the last line is clipped.
      PaneLayout(frames: pieces.map(\.frame)) {
        ForEach(pieces) { piece in
          pieceView(piece, panes: visible, metrics: metrics, cell: cell, line: line)
        }
      }
      // Behind the panes, and it does not take clicks. A wheel follows the
      // pointer; if the pane's own view has no frame yet, the event still
      // arrives here and the pane it lands on is the one that scrolls.
      .background { paneWheel(pieces: pieces, line: line) }
      .clipped()
      .onAppear { resize(geometry.size, full) }
      .onChange(of: geometry.size) { _, size in resize(size, full) }
      .onChange(of: fontSize) { _, _ in resize(geometry.size, full) }
    }
  }

  /// The pane under a point, in this view's top-left coordinates. Seams are
  /// not panes: a drag there resizes, and a wheel there is left alone.
  static func paneID(at point: CGPoint, in pieces: [PanePiece]) -> UInt32? {
    for piece in pieces {
      if case .pane(let id) = piece.kind, piece.frame.contains(point) { return id }
    }
    return nil
  }

  /// Where each pane and the seam beside it sits. Panes first, seams after,
  /// so a drag on the shared edge resizes and a drag on the grid selects.
  static func pieces(
    panes: [PaneBox], windowColumns: Int, windowRows: Int,
    cell: CGFloat, line: CGFloat, divider: CGFloat
  ) -> [PanePiece] {
    var surfaces: [PanePiece] = []
    var seams: [PanePiece] = []
    for pane in panes {
      let originX = CGFloat(pane.x) * cell
      let originY = CGFloat(pane.y) * line
      let width = CGFloat(pane.width) * cell
      let height = CGFloat(pane.height) * line
      surfaces.append(PanePiece(
        id: "pane-\(pane.id)", kind: .pane(pane.id),
        frame: CGRect(x: originX, y: originY, width: width, height: height)))
      if Int(pane.x) + Int(pane.width) < windowColumns {
        seams.append(PanePiece(
          id: "v-\(pane.id)", kind: .vertical(pane.id),
          frame: CGRect(x: originX + width - divider / 2, y: originY, width: divider, height: height)))
      }
      if Int(pane.y) + Int(pane.height) < windowRows {
        seams.append(PanePiece(
          id: "h-\(pane.id)", kind: .horizontal(pane.id),
          frame: CGRect(x: originX, y: originY + height - divider / 2, width: width, height: divider)))
      }
    }
    return surfaces + seams
  }

  /// Where a pane's surface goes. At least the grid. Free space beside and
  /// under it, up to the next pane or the view, belongs to the same surface:
  /// a frame that ends on the last row clips that row.
  static func surfaceFrame(
    pane: PaneBox, columns: Int, rows: Int, among panes: [PaneBox],
    cell: CGFloat, line: CGFloat, view: CGSize
  ) -> CGRect {
    let x = CGFloat(pane.x) * cell
    let y = CGFloat(pane.y) * line
    let gridWidth = max(CGFloat(pane.width), CGFloat(columns)) * cell
    let gridHeight = max(CGFloat(pane.height), CGFloat(rows)) * line
    var floor = view.height
    var rightEdge = view.width
    let bottom = y + CGFloat(pane.height) * line
    let right = x + CGFloat(pane.width) * cell
    for other in panes where other.id != pane.id {
      let otherTop = CGFloat(other.y) * line
      let otherLeft = CGFloat(other.x) * cell
      let otherRight = otherLeft + CGFloat(other.width) * cell
      let otherBottom = otherTop + CGFloat(other.height) * line
      if otherTop + 0.5 >= bottom, otherLeft < right, otherRight > x {
        floor = min(floor, otherTop)
      }
      if otherLeft + 0.5 >= right, otherTop < bottom, otherBottom > y {
        rightEdge = min(rightEdge, otherLeft)
      }
    }
    let roomHeight = floor - y
    let roomWidth = rightEdge - x
    return CGRect(
      x: x, y: y,
      width: roomWidth >= gridWidth ? roomWidth : gridWidth,
      height: roomHeight >= gridHeight ? roomHeight : gridHeight)
  }

  @ViewBuilder
  private func pieceView(
    _ piece: PanePiece, panes: [TmuxPaneFrame], metrics: FontMetrics, cell: CGFloat, line: CGFloat
  ) -> some View {
    switch piece.kind {
    case .pane(let id):
      if let pane = panes.first(where: { $0.id == id }) {
        // The grid can be a row taller than the layout cell count. The frame
        // follows the grid, or that row is sliced through the glyphs.
        let width = max(piece.frame.width, CGFloat(pane.frame.columns) * cell)
        let height = max(piece.frame.height, CGFloat(pane.frame.rows) * line)
        paneSurface(pane, metrics: metrics)
          .frame(width: width, height: height, alignment: .topLeading)
          .clipped()
      }
    case .vertical(let id):
      if let pane = panes.first(where: { $0.id == id }) {
        Rectangle().fill(.separator)
          .frame(width: piece.frame.width, height: piece.frame.height)
          .contentShape(Rectangle())
          .gesture(DragGesture().onEnded { value in
            model.perform(.resizePane(
              id: pane.id,
              columns: UInt16(max(1, min(1000, Int(pane.width) + Int(value.translation.width / cell)))),
              rows: pane.height))
          })
      }
    case .horizontal(let id):
      if let pane = panes.first(where: { $0.id == id }) {
        Rectangle().fill(.separator)
          .frame(width: piece.frame.width, height: piece.frame.height)
          .contentShape(Rectangle())
          .gesture(DragGesture().onEnded { value in
            model.perform(.resizePane(
              id: pane.id, columns: pane.width,
              rows: UInt16(max(1, min(500, Int(pane.height) + Int(value.translation.height / line))))))
          })
      }
    }
  }

  private func paneSurface(_ pane: TmuxPaneFrame, metrics: FontMetrics) -> some View {
    TerminalSurface(
      frame: pane.frame, active: pane.active, inset: 0,
      onInput: { model.send(pane.id, $0) },
      onFocus: { if !pane.active { model.perform(.selectPane(id: pane.id)) } },
      onScroll: { model.scroll(pane.id, lines: Self.lines(for: $0, page: Int32(pane.height))) },
      links: model.links(for: pane.id),
      metrics: metrics
    )
    .overlay(alignment: .topTrailing) {
      if pane.active {
        RoundedRectangle(cornerRadius: TmuxStyle.markerRadius).fill(Color.accentColor)
          .frame(width: TmuxStyle.markerWidth, height: TmuxStyle.markerHeight)
          .padding(TmuxStyle.markerInset).allowsHitTesting(false).accessibilityHidden(true)
      }
    }
  }

  /// The type size that puts the whole window inside the view.
  ///
  /// Never larger than what was asked for: this shrinks to fit and does
  /// nothing otherwise. Measured rather than scaled arithmetically, because
  /// a cell is a rounded advance and a size two thirds of another does not
  /// give two thirds of the cell.
  private func fitting(
    _ window: TmuxWindowInfo, in size: CGSize, asked: CGFloat, at full: FontMetrics
  ) -> FontMetrics {
    guard window.width > 0, window.height > 0, size.width > 0, size.height > 0 else { return full }
    // A point of slack. A grid that lands on the view's edge is clipped
    // through the last row's glyphs.
    func fits(_ metrics: FontMetrics) -> Bool {
      CGFloat(window.width) * metrics.cellWidth <= size.width - 1
        && CGFloat(window.height) * metrics.lineHeight <= size.height - 1
    }
    if fits(full) { return full }

    let scale = min(
      size.width / (CGFloat(window.width) * full.cellWidth),
      size.height / (CGFloat(window.height) * full.lineHeight))
    let chosen = Self.pointSize(asked: asked, scale: scale) { candidate in
      fits(FontMetrics(size: candidate))
    }
    return FontMetrics(size: chosen)
  }

  /// Whole point sizes from the asked size downward, until `fits` or the floor.
  /// Never larger than what was asked: a bigger face fills a small window and
  /// puts the last row back on the clip edge.
  static func pointSize(asked: CGFloat, scale: CGFloat, fits: (CGFloat) -> Bool) -> CGFloat {
    var candidate = min(asked, max(5, (asked * scale).rounded(.down)))
    while candidate > 5 {
      if fits(candidate) { return candidate }
      candidate -= 1
    }
    return 5
  }

  private func resize(_ size: CGSize, _ metrics: FontMetrics) {
    model.resize(metrics.columns(fitting: size.width), metrics.rows(fitting: size.height))
  }

  @ViewBuilder
  private func paneWheel(pieces: [PanePiece], line: CGFloat) -> some View {
    #if os(macOS)
      PaneWheel(pieces: pieces, lineHeight: line) { pane, lines in
        model.scroll(pane, lines: lines)
      }
    #endif
  }
}
/// A pane's place in the window, in tmux cells. The frame it draws is a
/// separate thing and is not needed to decide where the pointer lands.
struct PaneBox: Equatable {
  var id: UInt32
  var x: UInt16
  var y: UInt16
  var width: UInt16
  var height: UInt16
}

struct PanePiece: Identifiable, Equatable {
  enum Kind: Equatable {
    case pane(UInt32)
    case vertical(UInt32)
    case horizontal(UInt32)
  }

  var id: String
  var kind: Kind
  var frame: CGRect
}

/// Each child is given exactly its rectangle. The hit target is that
/// rectangle, which is what a wheel and a drag need and what `position`
/// does not give.
private struct PaneLayout: Layout {
  var frames: [CGRect]

  func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for index in subviews.indices where frames.indices.contains(index) {
      let frame = frames[index]
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: frame.width, height: frame.height))
    }
  }
}

#if os(macOS)
  /// Claims a wheel whose point is inside a pane, and nothing else.
  ///
  /// Returning the event would deliver it again to the pane underneath, and
  /// the history would move twice. A click is not claimed: selection stays
  /// with the pane.
  private struct PaneWheel: NSViewRepresentable {
    var pieces: [PanePiece]
    var lineHeight: CGFloat
    var onScroll: (UInt32, Int32) -> Void

    func makeNSView(context: Context) -> PaneWheelView {
      let view = PaneWheelView()
      apply(to: view)
      return view
    }

    func updateNSView(_ view: PaneWheelView, context: Context) { apply(to: view) }

    static func dismantleNSView(_ view: PaneWheelView, coordinator: Coordinator) { view.stop() }

    private func apply(to view: PaneWheelView) {
      view.pieces = pieces
      view.lineHeight = lineHeight
      view.onScroll = onScroll
    }
  }

  private final class PaneWheelView: NSView {
    var pieces: [PanePiece] = []
    var lineHeight: CGFloat = 1
    var onScroll: ((UInt32, Int32) -> Void)?
    private var monitor: Any?
    /// Fractional lines left over from the last wheel event.
    private var carried: CGFloat = 0
    private var tracking: UInt32?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else {
        stop()
        return
      }
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, self.take(event) else { return event }
        return nil
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      carried = 0
      tracking = nil
    }

    private func take(_ event: NSEvent) -> Bool {
      guard event.window === window, window?.attachedSheet == nil else { return false }
      guard bounds.width > 1, bounds.height > 1 else { return false }
      let point = convert(event.locationInWindow, from: nil)
      guard bounds.contains(point) else {
        carried = 0
        tracking = nil
        return false
      }
      guard let pane = TmuxContent.paneID(at: point, in: pieces) else { return false }
      if pane != tracking {
        tracking = pane
        carried = 0
      }
      let height = max(lineHeight, 1)
      carried += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / height : event.scrollingDeltaY
      let whole = carried.rounded(.towardZero)
      guard whole != 0 else { return true }
      carried -= whole
      let lines = Int(min(max(whole, -CGFloat(Int32.max)), CGFloat(Int32.max)))
      onScroll?(pane, Int32(clamping: lines))
      return true
    }
  }
#endif

struct TmuxInspector: View {
  @Bindable var model: TmuxTab
  var body: some View {
    Form {
      Section("Workspace") {
        LabeledContent("Host", value: model.tab.plugin.hostLabel)
        LabeledContent("Session", value: model.session?.name ?? "Not attached")
        LabeledContent(
          "Status",
          value: model.ended
            ? "Disconnected" : (model.session == nil ? "Not attached" : "Connected"))
      }
      if let pane = model.activePane {
        Section("Active pane") {
          LabeledContent("Size", value: "\(pane.width) × \(pane.height)")
          ForEach(model.paneCommands) { command in
            Button(command.title, systemImage: command.symbol, action: command.action)
          }
          Button("End pane…", role: .destructive) {
            model.pendingDestruction = .closePane(id: pane.id)
          }
        }.disabled(model.ended || model.busy)
      }
    }.formStyle(.grouped)
  }
}
