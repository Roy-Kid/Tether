import Testing
import TetherPluginKit

@testable import TetherApp

/// The host's lamp for a plugin that reports status as data.
@Suite("Status ribbon")
struct StatusRibbonTests {
  static func segment(_ color: UInt32, _ weight: Double) -> PluginStatusSegment {
    PluginStatusSegment(id: String(color), color: color, weight: weight)
  }

  @Test("nothing to report is the idle ribbon, not a band of nothing")
  func empty() {
    #expect(StatusRibbon.stops(for: []).isEmpty)
    #expect(StatusRibbon.stops(for: [Self.segment(0xFF0000, 0)]).isEmpty, "a zero share draws nothing")
  }

  @Test("one segment fills the band")
  func single() {
    #expect(StatusRibbon.stops(for: [Self.segment(0x00FF00, 3)]) == [
      .init(color: 0x00FF00, location: 0), .init(color: 0x00FF00, location: 1),
    ])
  }

  /// Each colour holds for its share and blends only at the boundary, never
  /// across a neighbour's whole width.
  @Test("shares hold their colour and blend at the boundary")
  func proportions() {
    let stops = StatusRibbon.stops(for: [Self.segment(0xFF0000, 3), Self.segment(0x0000FF, 1)])
    #expect(stops.first == .init(color: 0xFF0000, location: 0))
    #expect(stops.last == .init(color: 0x0000FF, location: 1))
    #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location <= $1.location })
    let lastRed = stops.last { $0.color == 0xFF0000 }!.location
    let firstBlue = stops.first { $0.color == 0x0000FF }!.location
    #expect(lastRed < 0.75 && 0.75 < firstBlue, "the boundary sits at the red share")
    #expect(firstBlue - lastRed <= StatusRibbon.blend + 1e-9)
  }
}
