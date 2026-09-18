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
public struct TerminalView: View {
  let frame: ScreenFrame
  let metrics: FontMetrics
  let palette: Palette

  public var body: some View {
    Canvas(rendersAsynchronously: false) { context, size in
      draw(in: &context, size: size)
    }
    .background(palette.background)
    .frame(
      minWidth: metrics.cellWidth * CGFloat(frame.columns),
      minHeight: metrics.lineHeight * CGFloat(frame.rows))
  }

  public init(frame: ScreenFrame, metrics: FontMetrics, palette: Palette) {
    self.frame = frame
    self.metrics = metrics
    self.palette = palette
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    for (index, row) in frame.lines.enumerated() {
      let y = metrics.lineHeight * CGFloat(index)
      var column = 0

      for run in row.runs {
        let x = metrics.cellWidth * CGFloat(column)
        let width = metrics.cellWidth * CGFloat(run.columns)

        draw(run: run, at: CGPoint(x: x, y: y), width: width, in: &context)
        column += Int(run.columns)
      }
    }

    drawCursor(in: &context)
    _ = size
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

    var text = Text(run.text)
      .font(metrics.font(bold: run.style.bold, italic: run.style.italic))
      .foregroundColor(run.style.dim ? foreground.opacity(0.6) : foreground)

    if run.style.strikethrough { text = text.strikethrough() }
    if case .none = run.style.underline {} else { text = text.underline() }

    context.draw(
      text,
      at: CGPoint(x: origin.x, y: origin.y + metrics.baseline),
      anchor: .bottomLeading)
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
public struct FontMetrics: Equatable, Sendable {
  let size: CGFloat
  public let cellWidth: CGFloat
  public let lineHeight: CGFloat
  let baseline: CGFloat

  /// Measures the advance of a single character rather than assuming one.
  /// A monospaced face still differs between sizes and weights, and a
  /// hard-coded ratio would misalign box drawing at some sizes and not
  /// others — the kind of bug that looks like a rendering glitch.
  public init(size: CGFloat) {
    // `NSFont` and `UIFont` are different types with the same metrics and the
    // same selectors, so the measurement is written once against whichever
    // one this platform has rather than twice against both.
    #if os(macOS)
      let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #else
      let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #endif

    self.size = size
    self.cellWidth = ceil(NSString(string: "M").size(withAttributes: [.font: font]).width)
    self.lineHeight = ceil(font.ascender - font.descender + font.leading)
    self.baseline = ceil(font.ascender)
  }

  func font(bold: Bool, italic: Bool) -> Font {
    var font = Font.system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
    if italic { font = font.italic() }
    return font
  }
}
