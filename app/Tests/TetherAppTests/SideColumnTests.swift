#if os(macOS)
  import SwiftUI
  import Testing

  @testable import TetherApp

  /// A side column's remembered width, read back from defaults.
  @MainActor
  @Suite("Side column")
  struct SideColumnTests {
    @Test("a stored width is kept inside the column's range")
    func clamping() {
      let range: ClosedRange<CGFloat> = 240...480
      #expect(SideColumn<EmptyView>.clamped(300, to: range) == 300)
      #expect(SideColumn<EmptyView>.clamped(100, to: range) == 240)
      #expect(SideColumn<EmptyView>.clamped(9_000, to: range) == 480)
      #expect(SideColumn<EmptyView>.clamped(.nan, to: range) == 240, "a corrupted default")
      #expect(SideColumn<EmptyView>.clamped(.infinity, to: range) == 240)
    }
  }
#endif
