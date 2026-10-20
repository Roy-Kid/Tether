import Testing
@testable import TetherUI

@MainActor
@Suite("Shared grid geometry")
struct GridTests {
  @Test("fitted cells never overflow and retain terminal size bounds")
  func fitting() {
    for scale in [1.0, 2.0, 3.0] {
      let metrics = FontMetrics(size: 13, scale: scale)
      for width in [0.0, 1.0, 7.0, 8.5, 100.0, 1100.4] {
        let columns = metrics.columns(fitting: width)
        let pixels = (width * scale).rounded()
        let cell = metrics.cellWidth * scale
        #expect(Double(columns) * cell <= pixels + 0.001 || columns == 1)
      }
      #expect(metrics.columns(fitting: 100000) == 1000)
      #expect(metrics.rows(fitting: 100000) == 500)
    }
  }
}
