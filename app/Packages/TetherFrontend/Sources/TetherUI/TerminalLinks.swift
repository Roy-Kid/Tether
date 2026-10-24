import SwiftUI
import Tether

/// What a terminal surface asks about the text under a pointer, and whom it
/// tells when a person uses it.
///
/// The surface knows where cells are and what a gesture is. What a path
/// *means* — whether it exists, how to show it — is the host's, which asks
/// whatever is attached to the tab. So this is three closures, and a surface
/// without them does nothing when pointed at.
public struct TerminalLinks {
  /// The link at a cell, if the text there names one. Asked when a person
  /// points, never per frame.
  public var find: (_ row: UInt16, _ column: UInt16) -> TerminalLink?
  /// ⌘-click or a force click on a Mac; tapping the preview on a phone.
  public var open: (TerminalLink) -> Void
  /// A right-click on a Mac, a long-press on a phone.
  public var menu: (TerminalLink) -> LinkMenu?
  /// Whether what a hovered link names is really there. The underline is
  /// dotted while this is asked, solid once it says yes, and gone if no.
  public var exists: @MainActor (TerminalLink) async -> Bool

  public init(
    find: @escaping (UInt16, UInt16) -> TerminalLink?,
    open: @escaping (TerminalLink) -> Void,
    menu: @escaping (TerminalLink) -> LinkMenu?,
    exists: @escaping @MainActor (TerminalLink) async -> Bool = { _ in true }
  ) {
    self.find = find
    self.open = open
    self.menu = menu
    self.exists = exists
  }

  /// A surface nobody asked links of: pointing does nothing.
  public static var none: TerminalLinks {
    TerminalLinks(find: { _, _ in nil }, open: { _ in }, menu: { _ in nil })
  }
}

/// The menu for a link, and a picture of what it points at.
public struct LinkMenu {
  public struct Item: Identifiable {
    public let id = UUID()
    public let title: String
    public let symbol: String
    public let destructive: Bool
    public let action: () -> Void

    public init(
      title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void
    ) {
      self.title = title
      self.symbol = symbol
      self.destructive = destructive
      self.action = action
    }
  }

  public let items: [Item]
  /// Shown above the menu on a phone. A Mac's context menu has no preview.
  public let preview: (() -> AnyView)?

  public init(items: [Item], preview: (() -> AnyView)? = nil) {
    self.items = items
    self.preview = preview
  }
}

/// Where cells are in the surface's own coordinates, top-left origin.
struct CellGeometry: Equatable {
  var cellWidth: CGFloat
  var lineHeight: CGFloat
  /// The grid's top-left corner. Not the inset alone: the renderer centres
  /// the grid in what the inset leaves, and a click has to land where the
  /// cell was drawn.
  var originX: CGFloat
  var originY: CGFloat
  var columns: UInt16
  var rows: UInt16

  init(cellWidth: CGFloat, lineHeight: CGFloat, inset: CGFloat, columns: UInt16, rows: UInt16) {
    self.init(cellWidth: cellWidth, lineHeight: lineHeight, originX: inset, originY: inset,
      columns: columns, rows: rows)
  }

  init(cellWidth: CGFloat, lineHeight: CGFloat, originX: CGFloat, originY: CGFloat, columns: UInt16, rows: UInt16) {
    self.cellWidth = cellWidth
    self.lineHeight = lineHeight
    self.originX = originX
    self.originY = originY
    self.columns = columns
    self.rows = rows
  }

  /// Where the renderer puts a grid on a surface of `size` points given
  /// `inset` (`RenderSurface.setGridPadding`): the same arithmetic, in the
  /// same device pixels, so the cell under the pointer is the cell drawn.
  static func placed(
    size: CGSize, scale: CGFloat, inset: CGFloat, cellWidth: CGFloat, lineHeight: CGFloat,
    columns: UInt16, rows: UInt16
  ) -> CellGeometry {
    let scale = scale > 0 ? scale : 1
    let insetPixels = gridPadding(inset: inset, scale: scale)
    func origin(_ points: CGFloat, _ pitch: CGFloat, _ count: UInt16) -> CGFloat {
      let available = (points * scale).rounded()
      let used = CGFloat(count) * (pitch * scale).rounded()
      let spare = max(0, available - 2 * insetPixels - used)
      return (insetPixels + (spare / 2).rounded(.down)) / scale
    }
    return CellGeometry(
      cellWidth: cellWidth, lineHeight: lineHeight,
      originX: origin(size.width, cellWidth, columns), originY: origin(size.height, lineHeight, rows),
      columns: columns, rows: rows)
  }

  /// The inset as the renderer is told it: whole device pixels.
  static func gridPadding(inset: CGFloat, scale: CGFloat) -> CGFloat {
    (max(0, inset) * (scale > 0 ? scale : 1)).rounded()
  }

  static let empty = CellGeometry(cellWidth: 1, lineHeight: 1, inset: 0, columns: 0, rows: 0)

  /// The cell under `point`, clamped to the grid. A drag that leaves the
  /// window still has an end; a click in the margin does not, and uses
  /// [`cell(at:)`] instead.
  func clampedCell(at point: CGPoint) -> (row: UInt16, column: UInt16)? {
    guard columns > 0, rows > 0, cellWidth > 0, lineHeight > 0 else { return nil }
    let column = min(max(Int((point.x - originX) / cellWidth), 0), Int(columns) - 1)
    let row = min(max(Int((point.y - originY) / lineHeight), 0), Int(rows) - 1)
    return (UInt16(row), UInt16(column))
  }

  /// The cell under `point`, or `nil` in the margin.
  func cell(at point: CGPoint) -> (row: UInt16, column: UInt16)? {
    let x = (point.x - originX) / cellWidth
    let y = (point.y - originY) / lineHeight
    guard x >= 0, y >= 0 else { return nil }
    let column = Int(x)
    let row = Int(y)
    guard column < Int(columns), row < Int(rows) else { return nil }
    return (UInt16(row), UInt16(column))
  }

  /// The rectangle a span covers.
  func rect(for span: LinkSpan) -> CGRect {
    CGRect(
      x: originX + CGFloat(span.start) * cellWidth,
      y: originY + CGFloat(span.row) * lineHeight,
      width: CGFloat(span.end - span.start) * cellWidth,
      height: lineHeight)
  }

  func rect(for link: TerminalLink) -> CGRect {
    link.spans.map(rect(for:)).reduce(CGRect.null) { $0.union($1) }
  }
}
