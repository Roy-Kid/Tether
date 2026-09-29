import Metal
import Tether
import Testing

@testable import TetherUI

/// The Metal path, drawn off screen and read back.
///
/// A renderer whose output nobody looks at in CI is one that can draw
/// nothing and pass every other test. These read the pixels.
@MainActor
@Suite("Metal rendering")
struct MetalRenderTests {
  private let metrics = FontMetrics(size: 13)
  private let scale = 2

  private func style(underline: UnderlineStyle = .none, strikethrough: Bool = false) -> CellStyle {
    CellStyle(
      foreground: .named(name: .foreground), background: .named(name: .background),
      underline: underline, underlineColor: nil, bold: false, dim: false, italic: false,
      strikethrough: strikethrough, inverse: false, hidden: false)
  }

  private func frame(_ rows: [ScreenRow], columns: UInt32 = 12, cursor: CaretShape = .hidden) -> ScreenFrame {
    ScreenFrame(
      columns: columns, rows: UInt32(rows.count), cursorRow: 0, cursorColumn: 0, cursorShape: cursor,
      cursorVisible: cursor != .hidden, alternateScreen: false, viewportOffset: 0, historyLines: 0, title: "",
      lines: rows)
  }

  private func row(_ text: String, _ style: CellStyle) -> ScreenRow {
    ScreenRow(runs: [StyledRun(text: text, columns: UInt32(text.count), style: style)])
  }

  /// Pixels of `rect` (points) whose colour is not the background's.
  private func inked(_ image: MetalSnapshot, _ rect: CGRect) -> Int {
    colours(image, rect).filter { $0 != image.rgb(x: image.width - 1, y: image.height - 1) }.count
  }

  private func colours(_ image: MetalSnapshot, _ rect: CGRect) -> [UInt32] {
    var found: [UInt32] = []
    for y in Int(rect.minY) * scale..<min(image.height, Int(rect.maxY) * scale) {
      for x in Int(rect.minX) * scale..<min(image.width, Int(rect.maxX) * scale) {
        found.append(image.rgb(x: x, y: y))
      }
    }
    return found
  }

  private func render(_ screen: ScreenFrame, dirty: Set<Int>?) throws -> MetalSnapshot? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let view = TerminalMetalView(device: device)
    view.present(frame: screen, dirtyRows: dirty, metrics: metrics, palette: .dark)
    return try #require(
      view.snapshot(
        width: Int(metrics.cellWidth) * Int(screen.columns), height: Int(metrics.lineHeight) * screen.lines.count,
        scale: scale))
  }

  /// Going back to a tab makes a new view whose first update says only
  /// that nothing changed. Every row must still be drawn.
  @Test("a new view draws every row, even when nothing changed last")
  func newViewDrawsEverything() throws {
    let screen = frame([row("hello", style()), row("world", style())])
    guard let image = try render(screen, dirty: []) else { return }
    let width = metrics.cellWidth * 5
    #expect(inked(image, CGRect(x: 0, y: 0, width: width, height: metrics.lineHeight)) > 20)
    #expect(inked(image, CGRect(x: 0, y: metrics.lineHeight, width: width, height: metrics.lineHeight)) > 20)
  }

  /// A long session meets more characters than one texture holds — a
  /// Chinese one sooner than most. Full is a reason to start the atlas
  /// again, not to stop drawing new characters.
  @Test("a full atlas starts again rather than dropping characters")
  func fullAtlas() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let atlas = GlyphAtlas(device: device, side: 64)
    let cell = CGSize(width: 8, height: 16)
    var generations: Set<Int> = []
    for scalar in 0x4E00..<0x4E40 {
      let text = String(UnicodeScalar(scalar)!)
      atlas.allowsReset = true
      #expect(atlas.glyph(text, bold: false, italic: false, points: cell, fontSize: 13, scale: 2) != nil)
      generations.insert(atlas.generation)
    }
    #expect(generations.count > 1, "the atlas filled and started again")
  }

  /// A block cursor, a coloured background, an underline: all drawn from
  /// one opaque patch of the atlas. Sampled across a single texel, that
  /// patch faded into its empty neighbour and every one of them shaded
  /// from corner to corner.
  @Test("a solid quad is one colour, edge to edge")
  func solidQuads() throws {
    guard let image = try render(frame([row("    ", style())], cursor: .block), dirty: nil) else { return }
    // Inset by a pixel: the edges of a quad fall between pixels.
    let cell = CGRect(x: 0.5, y: 0.5, width: metrics.cellWidth - 1, height: metrics.lineHeight - 1)
    #expect(Set(colours(image, cell)).count == 1)
    #expect(image.alpha(x: 0, y: 0) == 255, "opaque, not a hole in the layer")
  }

  @Test("underline and strikethrough are drawn, as the canvas draws them")
  func decorations() throws {
    let blank = row("    ", style())
    let plainRow = row("abcd", style())
    let lined = row("abcd", style(underline: .single, strikethrough: true))
    guard let plain = try render(frame([plainRow, blank]), dirty: nil),
      let decorated = try render(frame([lined, blank]), dirty: nil)
    else { return }
    let band = CGRect(x: 0, y: 0, width: metrics.cellWidth * 4, height: metrics.lineHeight)
    #expect(inked(decorated, band) > inked(plain, band) + Int(metrics.cellWidth) * 4)
  }
}
