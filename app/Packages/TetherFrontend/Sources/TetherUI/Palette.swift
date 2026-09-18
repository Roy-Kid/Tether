import SwiftUI
import Tether

/// Resolves the names the engine reports into colours this app draws.
///
/// The engine deliberately reports `red`, not an RGB triple, because the
/// consumer owns the palette (spec §12). This is that ownership being
/// exercised: one place decides what red means, and a light theme would be a
/// different instance of this struct rather than a change anywhere else.
public struct Palette: Equatable, Sendable {
  let background: Color
  let foreground: Color
  let cursor: Color
  let normal: [Color]
  let bright: [Color]

  /// A dark theme with the usual sixteen.
  public static let dark = Palette(
    background: Color(red: 0.07, green: 0.08, blue: 0.10),
    foreground: Color(red: 0.87, green: 0.88, blue: 0.90),
    cursor: Color(red: 0.55, green: 0.78, blue: 0.96),
    normal: [
      Color(red: 0.16, green: 0.17, blue: 0.20),  // black
      Color(red: 0.90, green: 0.38, blue: 0.40),  // red
      Color(red: 0.47, green: 0.76, blue: 0.45),  // green
      Color(red: 0.90, green: 0.72, blue: 0.36),  // yellow
      Color(red: 0.40, green: 0.62, blue: 0.90),  // blue
      Color(red: 0.76, green: 0.51, blue: 0.85),  // magenta
      Color(red: 0.36, green: 0.75, blue: 0.77),  // cyan
      Color(red: 0.78, green: 0.79, blue: 0.81),  // white
    ],
    bright: [
      Color(red: 0.34, green: 0.36, blue: 0.40),
      Color(red: 0.96, green: 0.50, blue: 0.51),
      Color(red: 0.60, green: 0.86, blue: 0.57),
      Color(red: 0.96, green: 0.82, blue: 0.48),
      Color(red: 0.53, green: 0.72, blue: 0.96),
      Color(red: 0.85, green: 0.63, blue: 0.93),
      Color(red: 0.48, green: 0.85, blue: 0.87),
      Color(red: 0.94, green: 0.95, blue: 0.96),
    ])

  public static let light = Palette(
    background: Color(red: 0.985, green: 0.985, blue: 0.99),
    foreground: Color(red: 0.12, green: 0.13, blue: 0.16),
    cursor: .blue,
    normal: [
      .black, Color(red: 0.7, green: 0.12, blue: 0.17), Color(red: 0.1, green: 0.4, blue: 0.2),
      Color(red: 0.55, green: 0.35, blue: 0.05), .blue, .purple,
      Color(red: 0, green: 0.4, blue: 0.5), .gray,
    ],
    bright: [
      .gray, .red, Color(red: 0.1, green: 0.5, blue: 0.25), .orange, .blue, .purple, .cyan, .white,
    ])

  func color(_ color: CellColor) -> Color {
    switch color {
    case .named(let name): named(name)
    case .indexed(let index): indexed(index)
    case .rgb(let red, let green, let blue):
      Color(
        red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
  }

  private func named(_ name: ColorName) -> Color {
    switch name {
    case .black: normal[0]
    case .red: normal[1]
    case .green: normal[2]
    case .yellow: normal[3]
    case .blue: normal[4]
    case .magenta: normal[5]
    case .cyan: normal[6]
    case .white: normal[7]
    case .brightBlack: bright[0]
    case .brightRed: bright[1]
    case .brightGreen: bright[2]
    case .brightYellow: bright[3]
    case .brightBlue: bright[4]
    case .brightMagenta: bright[5]
    case .brightCyan: bright[6]
    case .brightWhite: bright[7]
    case .foreground: foreground
    case .background: background
    case .cursor: cursor
    }
  }

  /// The standard 256-colour layout: sixteen named, then a 6×6×6 cube, then
  /// twenty-four greys. Computed rather than tabulated — the cube is
  /// genuinely a formula, and the levels are not evenly spaced, which is
  /// why the first step is 0 and the rest are 55 apart.
  private func indexed(_ index: UInt8) -> Color {
    switch index {
    case 0..<8:
      return normal[Int(index)]
    case 8..<16:
      return bright[Int(index) - 8]
    case 16..<232:
      let value = Int(index) - 16
      let level = { (step: Int) in step == 0 ? 0.0 : Double(55 + step * 40) / 255 }
      return Color(
        red: level(value / 36), green: level((value / 6) % 6), blue: level(value % 6))
    default:
      let grey = Double(8 + (Int(index) - 232) * 10) / 255
      return Color(red: grey, green: grey, blue: grey)
    }
  }
}
