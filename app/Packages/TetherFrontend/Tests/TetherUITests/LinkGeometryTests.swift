import CoreGraphics
import Testing
import Tether

@testable import TetherUI

@Suite("a wheel update")
struct WheelReportTests {
}

@Suite("one wheel, one owner")
struct WheelDispatchTests {
  private func route(
    lines: Int32 = 4, shift: Bool = false, mouse: MouseTracking = .off, hasCell: Bool = true,
    claim: WheelClaim = .pass
  ) -> (reports: Int, scrolled: Int32) {
    var reports = 0
    var scrolled: Int32 = 0
    WheelDispatch.route(
      lines: lines, shift: shift, mouse: mouse, hasCell: hasCell, claim: claim,
      report: { _ in reports += 1 }, scroll: { scrolled += $0 })
    return (reports, scrolled)
  }

  @Test("a taken wheel moves nothing else")
  func taken() {
    let moved = route(mouse: .clicks, claim: .taken)
    #expect(moved.reports == 0)
    #expect(moved.scrolled == 0)
  }

}

@Suite("pointing at a cell")
struct LinkGeometryTests {
  let geometry = CellGeometry(cellWidth: 8, lineHeight: 16, inset: 8, columns: 80, rows: 24)

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

}
