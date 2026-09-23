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
  var inset: CGFloat
  var columns: UInt16
  var rows: UInt16

  static let empty = CellGeometry(cellWidth: 1, lineHeight: 1, inset: 0, columns: 0, rows: 0)

  /// The cell under `point`, or `nil` in the margin.
  func cell(at point: CGPoint) -> (row: UInt16, column: UInt16)? {
    let x = (point.x - inset) / cellWidth
    let y = (point.y - inset) / lineHeight
    guard x >= 0, y >= 0 else { return nil }
    let column = Int(x)
    let row = Int(y)
    guard column < Int(columns), row < Int(rows) else { return nil }
    return (UInt16(row), UInt16(column))
  }

  /// The rectangle a span covers.
  func rect(for span: LinkSpan) -> CGRect {
    CGRect(
      x: inset + CGFloat(span.start) * cellWidth,
      y: inset + CGFloat(span.row) * lineHeight,
      width: CGFloat(span.end - span.start) * cellWidth,
      height: lineHeight)
  }

  func rect(for link: TerminalLink) -> CGRect {
    link.spans.map(rect(for:)).reduce(CGRect.null) { $0.union($1) }
  }
}

/// The underline under a link someone is pointing at: dotted while it is
/// being looked for, solid once it is known to be there.
struct LinkUnderline: View {
  let link: TerminalLink?
  let confirmed: Bool
  let geometry: CellGeometry

  var body: some View {
    Canvas { context, _ in
      guard let link else { return }
      for span in link.spans {
        let rect = geometry.rect(for: span)
        var line = Path()
        line.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
        line.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1))
        context.stroke(
          line, with: .color(.accentColor),
          style: StrokeStyle(lineWidth: 1, dash: confirmed ? [] : [2, 2]))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
