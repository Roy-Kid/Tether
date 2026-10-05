#if os(macOS)
  import SwiftUI
  import Testing
  import Tether

  @testable import TetherUI

  /// Whether a row of text lands on the same grid the cursor is drawn on.
  ///
  /// This is the arithmetic behind a bug that looks like a rendering glitch:
  /// the cell is a whole number of points wide, the font's own advance is not,
  /// and a run drawn as one string walks away from the grid a fraction of a
  /// point per character. At 13pt that fraction was most of a column, so by
  /// the eightieth column the cursor stood three characters away from the one
  /// it was on. Nothing crashes and no test noticed — which is why this one
  /// measures the drawn width against the grid rather than trusting the font.
  @Suite("Grid")
  @MainActor
  struct GridTests {
    /// Half a cell is the point at which the cursor visibly straddles two
    /// characters. Anything under a point is invisible and also unreachable:
    /// `measure` reports whole points.
    static let tolerance: CGFloat = 1

    @Test("measuring a size twice is the same measurement")
    func metricsAreStable() {
      for size in [10.0, 13.0, 24.0] as [CGFloat] {
        #expect(FontMetrics(size: size) == FontMetrics(size: size))
      }
    }

    @Test("a run of text is exactly as wide as the columns it covers")
    func narrowRunsKeepTheGrid() {
      for size in [10.0, 11.0, 12.0, 13.0, 14.0, 16.0, 18.0, 24.0] as [CGFloat] {
        let metrics = FontMetrics(size: size)
        let text = String(repeating: "M", count: 80)
        let drawn = measure(text, metrics: metrics, cells: 80)
        let grid = metrics.cellWidth * 80

        #expect(
          abs(drawn - grid) <= Self.tolerance,
          "at \(size)pt, eighty columns drew \(drawn)pt against a \(grid)pt grid")
      }
    }

    @Test("wide characters cover two columns each")
    func wideRunsKeepTheGrid() {
      let metrics = FontMetrics(size: 13)
      let text = String(repeating: "中", count: 20)
      let drawn = measure(text, metrics: metrics, cells: 40)
      let grid = metrics.cellWidth * 40

      #expect(
        abs(drawn - grid) <= Self.tolerance,
        "twenty wide characters drew \(drawn)pt against a \(grid)pt grid")
    }

    /// A cell is a whole number of points, so a column is in the same place
    /// on every row and text is not resampled differently line by line.
    @Test("a cell is a whole number of points wide")
    func cellsAreWhole() {
      for size in [10.0, 13.0, 18.0, 24.0] as [CGFloat] {
        let width = FontMetrics(size: size).cellWidth
        #expect(width == width.rounded(), "\(size)pt gave a \(width)pt cell")
        #expect(width >= 1)
      }
    }

    /// A fraction of a cell is not a cell. Rounding up is how the last
    /// column was drawn past the clip.
    @Test("cells that fit a view never exceed it")
    func fittingDoesNotOverflow() {
      let metrics = FontMetrics(size: 13)
      for width in [1.0, 7.0, 8.0, 8.5, 100.0, 1100.0, 1100.4] as [CGFloat] {
        let columns = metrics.columns(fitting: width)
        #expect(
          CGFloat(columns) * metrics.cellWidth <= width || columns == 1,
          "\(columns) columns of \(metrics.cellWidth)pt into \(width)pt")
      }
      #expect(metrics.columns(fitting: 0) == 1)
      #expect(metrics.columns(fitting: 10_000) == 1000)
    }

    /// A window smaller than the grid must not grow the view to the grid.
    /// That was the overflow: minWidth = columns × cell, the last cells
    /// painted past the window, and the table lost its right edge.
    @Test("a smaller proposed size is the size that is drawn")
    func gridDoesNotForceOverflow() {
      let metrics = FontMetrics(size: 13)
      let frame = ScreenFrame(
        columns: 200, rows: 40, cursorRow: 0, cursorColumn: 0,
        cursorShape: .hidden, cursorVisible: false, alternateScreen: false, mouse: .off,
        viewportOffset: 0, historyLines: 0, title: "",
        lines: [
          ScreenRow(
            runs: [
              StyledRun(
                text: String(repeating: "x", count: 200), columns: 200,
                style: CellStyle(
                  foreground: .named(name: .foreground),
                  background: .named(name: .background),
                  underline: .none, underlineColor: nil, bold: false, dim: false,
                  italic: false, strikethrough: false, inverse: false, hidden: false))
            ])
        ])
      let renderer = ImageRenderer(
        content: TerminalView(frame: frame, metrics: metrics, palette: .dark))
      renderer.proposedSize = ProposedViewSize(width: 400, height: 200)
      renderer.scale = 1
      let image = renderer.cgImage
      #expect(image != nil)
      if let image {
        #expect(image.width == 400, "proposed 400pt, got \(image.width)px")
        #expect(image.height == 200, "proposed 200pt, got \(image.height)px")
      }
    }

    @Test("row pictures follow display scale, geometry and palette without cell damage")
    func rowPicturesInvalidate() throws {
      let cache = RowPictureCache()
      let metrics = FontMetrics(size: 13)
      let line = ScreenRow(runs: [])
      func picture(columns: UInt32 = 12, palette: Palette = .dark, scale: CGFloat = 1,
                   font: FontMetrics? = nil, rows: Int = 1) throws -> CGImage {
        let measured = font ?? metrics
        cache.prepare(columns: columns, rows: rows, metrics: measured, palette: palette, scale: scale)
        return try #require(cache.image(row: 0, line: line, columns: columns,
                                       metrics: measured, palette: palette, fresh: false))
      }
      let original = try picture()
      #expect(try picture() === original, "unchanged rows reuse the picture")
      let retina = try picture(scale: 2)
      #expect(retina.width == original.width * 2)
      #expect(retina.height == original.height * 2)
      let wider = try picture(columns: 24, scale: 2)
      #expect(wider.width == retina.width * 2)
      let light = try picture(columns: 24, palette: .light, scale: 2)
      #expect(light !== wider, "a palette change repaints an undamaged row")
      let larger = try picture(columns: 24, palette: .light, scale: 2, font: FontMetrics(size: 24))
      #expect(larger.height > light.height)
      cache.prepare(columns: 24, rows: 0, metrics: FontMetrics(size: 24), palette: .light, scale: 2)
      #expect(try picture(columns: 24, palette: .light, scale: 2, font: FontMetrics(size: 24)) !== larger,
              "rows outside the viewport are released")
    }

    /// Resolves a run the way `TerminalView` draws it and reports its width.
    private func measure(_ text: String, metrics: FontMetrics, cells: Int) -> CGFloat {
      var width: CGFloat = 0
      let probe = Canvas(rendersAsynchronously: false) { context, _ in
        let resolved = context.resolve(
          Text(text)
            .font(metrics.font(bold: false, italic: false))
            .tracking(metrics.tracking(cells: cells, characters: text.count)))
        width = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
      }
      let renderer = ImageRenderer(content: probe.frame(width: 4000, height: 40))
      _ = renderer.cgImage
      return width
    }
  }
#endif
