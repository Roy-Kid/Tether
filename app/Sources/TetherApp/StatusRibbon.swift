import SwiftUI
import TetherPluginKit
import TetherUI

/// A status plugin's segments as one continuous band: each colour holds for
/// its share of the width and blends into the next at the boundary, so a
/// glance reads proportions rather than counting blocks.
///
/// Drawn by the host, so a plugin can report status as data alone —
/// `PluginStatusSegment` — without importing a UI framework, and so the lamp
/// looks the same on a Mac and on a phone.
struct StatusRibbon: View {
  let segments: [PluginStatusSegment]
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let dark = colorScheme == .dark
    Capsule()
      .fill(fill(dark: dark))
      .overlay(Capsule().stroke(Theme.stroke.opacity(dark ? 0.45 : 0.30), lineWidth: 0.5))
      .frame(height: Chrome.ribbonThickness)
      .padding(.horizontal, 2)
      .accessibilityHidden(true)
  }

  private func fill(dark: Bool) -> AnyShapeStyle {
    let stops = Self.stops(for: segments)
    guard !stops.isEmpty else { return AnyShapeStyle(Self.color(Self.idle, dark: dark).opacity(0.55)) }
    return AnyShapeStyle(LinearGradient(
      stops: stops.map { Gradient.Stop(color: Self.color($0.color, dark: dark), location: $0.location) },
      startPoint: .leading, endPoint: .trailing))
  }

  /// What an empty ribbon shows: something is reporting, nothing is happening.
  nonisolated static let idle: UInt32 = 0x8E8E93
  /// How much of the width, at most, two neighbours spend blending.
  nonisolated static let blend = 0.11

  nonisolated struct Stop: Equatable {
    var color: UInt32
    var location: Double
  }

  /// Where each colour starts and stops being itself.
  ///
  /// A boundary blends over a span that never exceeds either neighbour's
  /// share, so a thin segment stays visible beside a wide one instead of
  /// being smeared into it.
  nonisolated static func stops(for segments: [PluginStatusSegment]) -> [Stop] {
    let visible = segments.filter { $0.weight.isFinite && $0.weight > 0 }
    guard let first = visible.first else { return [] }
    guard visible.count > 1 else { return [Stop(color: first.color, location: 0), Stop(color: first.color, location: 1)] }

    // Scale first: valid finite shares can still overflow when added.
    let largest = visible.map(\.weight).max()!
    let scaled = visible.map { $0.weight / largest }
    let total = scaled.reduce(0, +)
    let weights = scaled.map { $0 / total }
    var stops: [Stop] = []
    var cursor = 0.0
    for (index, segment) in visible.enumerated() {
      let end = cursor + weights[index]
      let incoming = index == 0 ? 0 : min(blend, min(weights[index], weights[index - 1]) * 0.45)
      let outgoing = index == visible.count - 1 ? 0 : min(blend, min(weights[index], weights[index + 1]) * 0.45)
      let pureStart = min(end, cursor + incoming / 2)
      let pureEnd = max(pureStart, end - outgoing / 2)
      if index == 0 { stops.append(Stop(color: segment.color, location: 0)) }
      stops.append(Stop(color: segment.color, location: pureStart))
      stops.append(Stop(color: segment.color, location: pureEnd))
      if index < visible.count - 1 {
        stops.append(Stop(color: visible[index + 1].color, location: min(1, end + outgoing / 2)))
      } else {
        stops.append(Stop(color: segment.color, location: 1))
      }
      cursor = end
    }

    // Stops closer than a hair are one stop; the later colour is the one
    // that begins there.
    var cleaned: [Stop] = []
    for stop in stops.sorted(by: { $0.location < $1.location }) {
      let location = min(1, max(0, stop.location))
      if let last = cleaned.last, abs(last.location - location) < 0.004 {
        cleaned[cleaned.count - 1] = Stop(color: stop.color, location: location)
      } else {
        cleaned.append(Stop(color: stop.color, location: location))
      }
    }
    return cleaned
  }

  /// `0xRRGGBB` in sRGB, a touch lighter on a dark background so it holds
  /// the same weight there.
  nonisolated static func color(_ hex: UInt32, dark: Bool) -> Color {
    let lift = dark ? 0.04 : 0
    func channel(_ shift: UInt32) -> Double {
      let value = Double((hex >> shift) & 0xFF) / 255
      return value + (1 - value) * lift
    }
    return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0))
  }
}
