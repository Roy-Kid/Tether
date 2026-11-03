import SwiftUI

/// One clock for the status ribbon and every status dot of the same colour.
public enum StatusMotion {
  /// Gray stays still. A saturated colour breathes; the same colour always
  /// shares one period, so a tab mark and its ribbon band stay in phase.
  public nonisolated static func period(for color: UInt32) -> Double? {
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
  public nonisolated static func pulse(color: UInt32, time: TimeInterval) -> Double {
    guard let period = period(for: color), period > 0 else { return 1 }
    let phase = (time / period).truncatingRemainder(dividingBy: 1)
    return 0.72 + 0.28 * (0.5 + 0.5 * sin(phase * 2 * Double.pi))
  }

  /// 0...1 position of the glint, one trip every 1.8s.
  public nonisolated static func shimmer(time: TimeInterval) -> Double {
    let phase = (time / 1.8).truncatingRemainder(dividingBy: 1)
    return phase < 0 ? phase + 1 : phase
  }
}

/// A status plugin's mark: a dot, its meaning on hover. The tab strip puts it
/// in the tab icon's place; a plugin's own list puts it before a row's name.
/// Its opacity uses the ribbon's clock, so a running row and that colour on
/// the lamp breathe together.
public struct StatusDot: View {
  public static let size: CGFloat = 11
  let color: UInt32
  let label: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(color: UInt32, label: String) {
    self.color = color
    self.label = label
  }

  public var body: some View {
    let moving = !reduceMotion && StatusMotion.period(for: color) != nil
    TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !moving)) { timeline in
      let alpha = moving
        ? StatusMotion.pulse(color: color, time: timeline.date.timeIntervalSinceReferenceDate) : 1
      Circle()
        .fill(Color(hex: color).opacity(alpha))
        .frame(width: 8, height: 8)
    }
    .frame(width: Self.size, height: Self.size)
    .help(label)
    .accessibilityLabel(label)
  }
}
