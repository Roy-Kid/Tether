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
/// One clock for the status ribbon and the tab mark of the same colour.
enum StatusMotion {
  /// Gray stays still. A saturated colour breathes; the same colour always
  /// shares one period, so a tab mark and its ribbon band stay in phase.
  nonisolated static func period(for color: UInt32) -> Double? {
    let r = Double((color >> 16) & 0xFF)
    let g = Double((color >> 8) & 0xFF)
    let b = Double(color & 0xFF)
    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let chroma = maxC - minC
    guard chroma >= 28, maxC > 0 else { return nil }
    let hue: Double
    if r == maxC { hue = (g - b) / chroma }
    else if g == maxC { hue = 2 + (b - r) / chroma }
    else { hue = 4 + (r - g) / chroma }
    let unit = ((hue.truncatingRemainder(dividingBy: 6)) + 6).truncatingRemainder(dividingBy: 6) / 6
    return 0.9 + unit * 1.7
  }

  /// 0.72...1, or 1 when the colour does not move.
  nonisolated static func pulse(color: UInt32, time: TimeInterval) -> Double {
    guard let period = period(for: color), period > 0 else { return 1 }
    let phase = (time / period).truncatingRemainder(dividingBy: 1)
    return 0.72 + 0.28 * (0.5 + 0.5 * sin(phase * 2 * Double.pi))
  }

  /// 0...1 position of the glint, one trip every 1.8s.
  nonisolated static func shimmer(time: TimeInterval) -> Double {
    let phase = (time / 1.8).truncatingRemainder(dividingBy: 1)
    return phase < 0 ? phase + 1 : phase
  }
}

struct StatusRibbon: View {
  let segments: [PluginStatusSegment]
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var shares: [(color: UInt32, weight: Double)] { Self.shares(for: segments) }
  private var animates: Bool {
    !reduceMotion && shares.contains { StatusMotion.period(for: $0.color) != nil }
  }

  var body: some View {
    let dark = colorScheme == .dark
    TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animates)) { timeline in
      band(dark: dark, time: animates ? timeline.date.timeIntervalSinceReferenceDate : nil)
    }
    .frame(height: Chrome.ribbonThickness)
    .padding(.horizontal, 2)
    .accessibilityHidden(true)
  }

  private func band(dark: Bool, time: TimeInterval?) -> some View {
    let shape = Capsule()
    return ZStack {
      if let time {
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            HStack(spacing: 0) {
              ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                Rectangle()
                  .fill(Self.color(share.color, dark: dark)
                    .opacity(StatusMotion.pulse(color: share.color, time: time)))
                  .frame(width: max(1, geo.size.width * share.weight))
              }
            }
            shimmer(time: time, width: geo.size.width)
          }
        }
      } else {
        shape.fill(fill(dark: dark))
      }
    }
    .clipShape(shape)
    .overlay(shape.stroke(Theme.stroke.opacity(dark ? 0.45 : 0.30), lineWidth: 0.5))
  }

  private func shimmer(time: TimeInterval, width: CGFloat) -> some View {
    let travel = width * 1.7
    let x = -width * 0.35 + StatusMotion.shimmer(time: time) * travel
    return LinearGradient(
      colors: [.white.opacity(0), .white.opacity(colorScheme == .dark ? 0.22 : 0.16), .white.opacity(0)],
      startPoint: .leading, endPoint: .trailing)
      .frame(width: max(12, width * 0.45))
      .offset(x: x)
      .allowsHitTesting(false)
  }

  private func fill(dark: Bool) -> AnyShapeStyle {
    let stops = Self.stops(for: segments)
    // Idle is a tint of the bar's own ink, as every other chrome fill is:
    // a fixed grey on glass reads as a solid bar laid over the window.
    guard !stops.isEmpty else { return AnyShapeStyle(Theme.text.opacity(UIStyle.pressedOpacity)) }
    return AnyShapeStyle(LinearGradient(
      stops: stops.map { Gradient.Stop(color: Self.color($0.color, dark: dark), location: $0.location) },
      startPoint: .leading, endPoint: .trailing))
  }

  /// Normalised shares of the ribbon, in report order. Zero and non-finite
  /// weights drop out, matching `stops(for:)`.
  nonisolated static func shares(for segments: [PluginStatusSegment]) -> [(color: UInt32, weight: Double)] {
    let visible = segments.filter { $0.weight.isFinite && $0.weight > 0 }
    guard let largest = visible.map(\.weight).max(), largest > 0 else { return [] }
    let scaled = visible.map { $0.weight / largest }
    let total = scaled.reduce(0, +)
    guard total > 0 else { return [] }
    return zip(visible, scaled).map { ($0.0.color, $0.1 / total) }
  }

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
