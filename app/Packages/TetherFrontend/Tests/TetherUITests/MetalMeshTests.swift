import Tether
import Testing

@testable import TetherUI

@Suite("Metal mesh")
struct MetalMeshTests {
  @Test("a row's quads cover its runs and stop at the screen")
  func coveredColumnsStayInsideTheScreen() {
    let line = ScreenRow(runs: [
      StyledRun(text: "ab", columns: 2, style: plain),
      StyledRun(text: "c", columns: 1, style: plain),
    ])
    #expect(MetalMesh.coveredColumns(line, limit: 80) == 3)
    #expect(MetalMesh.coveredColumns(line, limit: 2) == 2)
    #expect(MetalMesh.coveredColumns(line, limit: 0) == 0)
  }

  /// Going back to a terminal makes a new view for it, and the last update
  /// that tab published said only that the cursor moved — or nothing at all.
  /// A view that drew only what changed last showed an empty screen until
  /// something else changed.
  @Test("a new view builds every row, whatever changed last")
  func newViewBuildsEverything() {
    #expect(MetalMesh.rowsToBuild(dirty: [], lines: 4, built: []) == [0, 1, 2, 3])
    #expect(MetalMesh.rowsToBuild(dirty: [2], lines: 4, built: []) == [0, 1, 2, 3])
  }

  @Test("a view that has every row rebuilds only the changed ones")
  func changedRowsOnly() {
    #expect(MetalMesh.rowsToBuild(dirty: [2], lines: 4, built: [0, 1, 2, 3]) == [2])
    #expect(MetalMesh.rowsToBuild(dirty: [], lines: 4, built: [0, 1, 2, 3]).isEmpty, "only the cursor moved")
    #expect(MetalMesh.rowsToBuild(dirty: nil, lines: 4, built: [0, 1, 2, 3]) == [0, 1, 2, 3])
    #expect(MetalMesh.rowsToBuild(dirty: [1], lines: 5, built: [0, 1, 2, 3]) == [1, 4], "a row the screen grew")
  }

  private var plain: CellStyle {
    CellStyle(
      foreground: .named(name: .foreground), background: .named(name: .background),
      underline: .none, underlineColor: nil, bold: false, dim: false, italic: false,
      strikethrough: false, inverse: false, hidden: false)
  }
}
