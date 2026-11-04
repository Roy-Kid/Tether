import Testing
import TetherPluginKit
import TetherUI

@testable import TetherApp

/// The host's lamp for a plugin that reports status as data.
@Suite("Status ribbon")
struct StatusRibbonTests {
  static func segment(_ color: UInt32, _ weight: Double) -> PluginStatusSegment {
    PluginStatusSegment(id: String(color), color: color, weight: weight)
  }

  @Test("invalid shares are ignored and large finite shares keep their proportions")
  func unusualWeights() {
    let invalid = [Double.nan, .infinity, -.infinity, -1, 0].map { Self.segment(0xFF0000, $0) }
    #expect(StatusRibbon.stops(for: invalid).isEmpty)
    let large = Double.greatestFiniteMagnitude
    let stops = StatusRibbon.stops(for: [Self.segment(0xFF0000, large), Self.segment(0x0000FF, large)])
    #expect(stops == StatusRibbon.stops(for: [Self.segment(0xFF0000, 1), Self.segment(0x0000FF, 1)]))
    #expect(stops.allSatisfy { $0.location.isFinite })
  }

}
