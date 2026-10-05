import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif
import Tether

/// Draws a frame.
///
/// Rows are laid out by hand rather than handed to a text container, because
/// a terminal is a grid: every cell is one column wide (or two), and letting
/// the text system decide advances would drift out of alignment within a line
/// of box-drawing characters. So the geometry comes from one measurement of
/// the font, and each run is placed at a column.
///
/// Placing a run is only half of it. A run is still drawn as one string, and
/// a string drawn at the font's own advance drifts inside itself — so every
/// run is also *spaced* to the grid it was placed on. Both halves are
/// measured in `FontMetrics`; getting the second one wrong is what leaves a
/// cursor standing next to the character it is on rather than over it.
public struct TerminalView: View {
  let frame: ScreenFrame
  /// `nil` redraws every row. An empty set leaves the row pictures alone.
  var dirtyRows: Set<Int>?
  let metrics: FontMetrics
  let palette: Palette
  var cache: RowPictureCache?
  @Environment(\.displayScale) private var displayScale

  public var body: some View {
    Canvas(rendersAsynchronously: false) { context, size in
      draw(in: &context, size: size)
    }
    .background(palette.background)
    // Ideal size is the grid, for a renderer that asks. It is not a
    // minimum: a minWidth of columns × cell made the view larger than the
    // window, and the last cells were clipped rather than never asked for.
    // It does fill, though — a canvas left at ideal size paints the grid in
    // a hole beside the pane's background, which reads as a mis-sized
    // terminal whenever the two palettes differ.
    .frame(
      minWidth: 0,
      idealWidth: metrics.cellWidth * CGFloat(frame.columns),
      maxWidth: .infinity,
      minHeight: 0,
      idealHeight: metrics.lineHeight * CGFloat(frame.rows),
      maxHeight: .infinity)
  }

  public init(frame: ScreenFrame, metrics: FontMetrics, palette: Palette) {
    self.frame = frame
    self.dirtyRows = nil
    self.metrics = metrics
    self.palette = palette
    self.cache = nil
  }

  init(
    frame: ScreenFrame, dirtyRows: Set<Int>?, metrics: FontMetrics, palette: Palette,
    cache: RowPictureCache
  ) {
    self.frame = frame
    self.dirtyRows = dirtyRows
    self.metrics = metrics
    self.palette = palette
    self.cache = cache
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    context.clip(to: Path(CGRect(origin: .zero, size: size)))

    let visibleColumns = max(0, Int(size.width / metrics.cellWidth) + 1)
    let visibleRows = min(frame.lines.count, max(0, Int(size.height / metrics.lineHeight) + 1))

    let pictures = cache
    pictures?.prepare(columns: frame.columns, rows: visibleRows, metrics: metrics,
                      palette: palette, scale: displayScale)
    for index in 0..<visibleRows {
      let row = frame.lines[index]
      let y = metrics.lineHeight * CGFloat(index)
      let rebuild = dirtyRows?.contains(index) ?? true
      if let image = pictures?.image(
        row: index, line: row, columns: frame.columns, metrics: metrics, palette: palette,
        fresh: rebuild)
      {
        let rowWidth = metrics.cellWidth * CGFloat(frame.columns)
        context.draw(
          Image(decorative: image, scale: 1),
          in: CGRect(x: 0, y: y, width: rowWidth, height: metrics.lineHeight))
        continue
      }
      var column = 0
      for run in row.runs {
        if column >= visibleColumns { break }
        let x = metrics.cellWidth * CGFloat(column)
        let width = metrics.cellWidth * CGFloat(run.columns)
        draw(run: run, at: CGPoint(x: x, y: y), width: width, in: &context)
        column += Int(run.columns)
      }
    }

    drawCursor(in: &context)
  }

  private func draw(
    run: StyledRun,
    at origin: CGPoint,
    width: CGFloat,
    in context: inout GraphicsContext
  ) {
    // `inverse` is a flag rather than pre-swapped colours so that a
    // renderer can decide; this one decides by swapping, which is what a
    // terminal does.
    let foreground = palette.color(run.style.inverse ? run.style.background : run.style.foreground)
    let background = palette.color(run.style.inverse ? run.style.foreground : run.style.background)

    if background != palette.background {
      context.fill(
        Path(CGRect(x: origin.x, y: origin.y, width: width, height: metrics.lineHeight)),
        with: .color(background))
    }

    // Text present but not to be drawn: what a shell does while reading a
    // password. The background above is still painted, so the cell does
    // not become a hole in a highlighted region.
    guard !run.style.hidden, !run.text.allSatisfy(\.isWhitespace) else { return }

    // Tracking, not the font's own advance. A monospaced face advances by a
    // fraction of a point that has nothing to do with the cell, so a run
    // drawn as one string walks away from the grid a little per character —
    // most of a column across an eighty-column line, which is why the cursor
    // stopped standing over the character it is on. Spacing each character
    // to exactly one cell puts the two back together.
    var text = Text(run.text)
      .font(metrics.font(bold: run.style.bold, italic: run.style.italic))
      .tracking(metrics.tracking(cells: Int(run.columns), characters: run.text.count))
      .foregroundColor(run.style.dim ? foreground.opacity(0.6) : foreground)

    if run.style.strikethrough { text = text.strikethrough() }
    if case .none = run.style.underline {} else { text = text.underline() }

    // Top of the cell, not its baseline. `anchor` places the text's *box*,
    // whose bottom sits a descender below the baseline, so asking for the
    // baseline drew every row a descender high — half a row out of step with
    // the cursor block, which is drawn on the cell.
    context.draw(text, at: origin, anchor: .topLeading)
  }

  private func drawCursor(in context: inout GraphicsContext) {
    // Hidden is a shape as well as a flag: a full-screen program hides
    // the cursor constantly while redrawing, and drawing it anyway is how
    // a terminal ends up with a block flickering across the screen.
    guard frame.cursorVisible else { return }

    let x = metrics.cellWidth * CGFloat(frame.cursorColumn)
    let y = metrics.lineHeight * CGFloat(frame.cursorRow)

    let shape: CGRect =
      switch frame.cursorShape {
      case .block:
        CGRect(x: x, y: y, width: metrics.cellWidth, height: metrics.lineHeight)
      case .underline:
        CGRect(x: x, y: y + metrics.lineHeight - 2, width: metrics.cellWidth, height: 2)
      case .beam:
        CGRect(x: x, y: y, width: 2, height: metrics.lineHeight)
      case .hidden:
        .null
      }

    guard !shape.isNull else { return }
    // Blended rather than filled, so the character underneath stays
    // readable inside a block cursor without drawing it twice.
    context.fill(Path(shape), with: .color(palette.cursor.opacity(0.75)))
  }
}

/// One measurement of the monospaced font, reused for every cell.
///
/// The cell is a whole number of points wide so that a column lands on the
/// same place every time, and the font is then *spaced into* that cell rather
/// than trusted to fill it. Those are two different numbers: SF Mono advances
/// 8.04pt at 13pt, and a grid built on 8 that draws text at 8.04 is a grid
/// whose eightieth column is three characters out.
public struct FontMetrics: Equatable, Sendable {
  let size: CGFloat
  public let cellWidth: CGFloat
  public let lineHeight: CGFloat
  /// What one column costs the font, before it is spaced to `cellWidth`.
  private let narrowAdvance: CGFloat
  /// The same for a character that covers two columns. Measured rather than
  /// doubled: CJK comes from a fallback face whose advance is its own, and
  /// assuming twice the Latin one misplaces every character after the first.
  private let wideAdvance: CGFloat

  /// Measures the advance of a single character rather than assuming one.
  /// A monospaced face still differs between sizes and weights, and a
  /// hard-coded ratio would misalign box drawing at some sizes and not
  /// others — the kind of bug that looks like a rendering glitch.
  public init(size: CGFloat) {
    if let cached = FontMetricsCache.shared.metrics(for: size) {
      self = cached
      return
    }
    // `NSFont` and `UIFont` are different types with the same metrics and the
    // same selectors, so the measurement is written once against whichever
    // one this platform has rather than twice against both.
    #if os(macOS)
      let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #else
      let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #endif

    let advance = NSString(string: "M").size(withAttributes: [.font: font]).width
    self.size = size
    self.narrowAdvance = advance
    self.wideAdvance = NSString(string: "\u{4e2d}").size(withAttributes: [.font: font]).width
    // Nearest, not up: rounding up added most of a point per column at 13pt,
    // and the text then had to be stretched by that much to keep up.
    self.cellWidth = max(1, advance.rounded())
    self.lineHeight = ceil(font.ascender - font.descender + font.leading)
    // Body evaluation asks for this on every frame. The numbers do not
    // change until the size does, so the measurement is once per size.
    FontMetricsCache.shared.store(self, for: size)
  }

  /// The extra advance that makes `characters` characters cover exactly
  /// `cells` columns.
  ///
  /// A run carries one cell width throughout — the boundary is drawn where it
  /// changes — so this is a division rather than a per-character measurement
  /// on the drawing path.
  func tracking(cells: Int, characters: Int) -> CGFloat {
    guard characters > 0 else { return 0 }
    let columns = CGFloat(cells) / CGFloat(characters)
    let advance = columns > 1.5 ? wideAdvance : narrowAdvance
    return columns * cellWidth - advance
  }

  func font(bold: Bool, italic: Bool) -> Font {
    var font = Font.system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
    if italic { font = font.italic() }
    return font
  }

  /// How many cells of this font fit in a view, which is also the size a
  /// terminal is told it is. Floor, not nearest: a fraction of a cell is
  /// not a cell, and rounding up is how the last column was drawn past the
  /// clip and never seen.
  public func columns(fitting width: CGFloat) -> UInt16 {
    UInt16(min(1000, max(1, width / cellWidth)))
  }

  public func rows(fitting height: CGFloat) -> UInt16 {
    UInt16(min(500, max(1, height / lineHeight)))
  }
}

/// Pictures of rows that have not changed. A keystroke rebuilds the rows
/// the damage named; the rest are drawn from here.
@MainActor
final class RowPictureCache {
  private var entries: [Int: (line: ScreenRow, image: CGImage)] = [:]
  private struct Configuration: Equatable {
    let columns: UInt32
    let metrics: FontMetrics
    let palette: Palette
    let scale: CGFloat
  }
  private var configuration: Configuration?
  private var retainedRows = 0

  /// Damage describes cells, not font, colour or display changes. Those
  /// invalidate every picture even when the session reports no dirty rows.
  func prepare(columns: UInt32, rows: Int, metrics: FontMetrics, palette: Palette, scale: CGFloat) {
    let next = Configuration(columns: columns, metrics: metrics, palette: palette, scale: scale)
    if configuration != next {
      clear()
      configuration = next
    }
    // A smaller window must not keep images for rows it no longer draws.
    if rows < retainedRows {
      for row in rows..<retainedRows { entries[row] = nil }
    }
    retainedRows = rows
  }

  func clear() {
    entries.removeAll()
  }

  func image(
    row: Int, line: ScreenRow, columns: UInt32, metrics: FontMetrics, palette: Palette, fresh: Bool
  ) -> CGImage? {
    if !fresh, let cached = entries[row], cached.line == line {
      return cached.image
    }
    guard let image = RowPictureCache.rasterize(line: line, columns: columns, metrics: metrics, palette: palette, scale: configuration?.scale ?? 1)
    else { return nil }
    entries[row] = (line, image)
    return image
  }

  private static func rasterize(
    line: ScreenRow, columns: UInt32, metrics: FontMetrics, palette: Palette, scale: CGFloat
  ) -> CGImage? {
    let width = max(columns, 1)
    let frame = ScreenFrame(
      columns: width, rows: 1, cursorRow: 0, cursorColumn: 0, cursorShape: .hidden,
      cursorVisible: false, alternateScreen: false, mouse: .off, viewportOffset: 0, historyLines: 0,
      title: "", lines: [line])
    let view = TerminalView(frame: frame, metrics: metrics, palette: palette)
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    renderer.proposedSize = ProposedViewSize(
      width: metrics.cellWidth * CGFloat(width), height: metrics.lineHeight)
    return renderer.cgImage
  }
}

private final class FontMetricsCache: @unchecked Sendable {
  static let shared = FontMetricsCache()
  private let lock = NSLock()
  private var values: [CGFloat: FontMetrics] = [:]

  func metrics(for size: CGFloat) -> FontMetrics? {
    lock.lock()
    defer { lock.unlock() }
    return values[size]
  }

  func store(_ metrics: FontMetrics, for size: CGFloat) {
    lock.lock()
    values[size] = metrics
    lock.unlock()
  }
}
