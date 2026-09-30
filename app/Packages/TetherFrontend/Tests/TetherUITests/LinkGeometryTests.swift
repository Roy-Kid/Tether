import CoreGraphics
import Testing
import Tether

@testable import TetherUI

@Suite("pointing at a cell")
struct LinkGeometryTests {
  let geometry = CellGeometry(cellWidth: 8, lineHeight: 16, inset: 8, columns: 80, rows: 24)

  @Test("a point inside a cell names that cell")
  func cellAtPoint() {
    #expect(geometry.cell(at: CGPoint(x: 8, y: 8))! == (0, 0))
    #expect(geometry.cell(at: CGPoint(x: 8 + 8 * 5 + 7.9, y: 8 + 16 * 2 + 1))! == (2, 5))
  }

  @Test("the margin and the space past the last cell name nothing")
  func outside() {
    #expect(geometry.cell(at: CGPoint(x: 7, y: 20)) == nil)
    #expect(geometry.cell(at: CGPoint(x: 20, y: 4)) == nil)
    #expect(geometry.cell(at: CGPoint(x: 8 + 8 * 80, y: 20)) == nil)
    #expect(geometry.cell(at: CGPoint(x: 20, y: 8 + 16 * 24)) == nil)
  }

  @Test("a drag that leaves the grid ends on the nearest cell")
  func clamped() {
    #expect(geometry.clampedCell(at: CGPoint(x: -10, y: -10))! == (0, 0))
    #expect(geometry.clampedCell(at: CGPoint(x: 10_000, y: 10_000))! == (23, 79))
  }

  @Test("a wrapped link covers both rows it is drawn on")
  func rectsForSpans() {
    let link = TerminalLink(
      text: "/data/run.dat", kind: .path(path: "/data/run.dat", line: nil, column: nil),
      spans: [LinkSpan(row: 0, start: 76, end: 80), LinkSpan(row: 1, start: 0, end: 9)])
    #expect(geometry.rect(for: link.spans[0]) == CGRect(x: 616, y: 8, width: 32, height: 16))
    #expect(geometry.rect(for: link) == CGRect(x: 8, y: 8, width: 640, height: 32))
  }
}
