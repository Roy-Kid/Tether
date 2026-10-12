import SwiftUI
import Tether

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Resolves the names the engine reports into colours this app draws.
///
/// The engine deliberately reports `red`, not an RGB triple, because the
/// consumer owns the palette (spec §12). This is that ownership being
/// exercised: one place decides what red means, and a light theme would be a
/// different instance of this struct rather than a change anywhere else.
public struct Palette: Equatable, Sendable {
  public let background: Color
  public let foreground: Color
  let cursor: Color
  let normal: [Color]
  let bright: [Color]

  /// A dark theme. The six chromatic hues are the status colours, so a
  /// program that asks for red and the lamp that means the same thing agree.
  /// Every slot but the two blacks reads as text here (4.5:1); black is
  /// mostly painted as a background, and bright black is the dim grey
  /// programs use for what should recede, so it only has to be seen (3:1).
  public static let dark = Palette(
    background: srgb(0x12141A),
    foreground: srgb(0xDEE0E6),
    cursor: srgb(0x0A84FF),
    normal: [
      srgb(0x292B33),  // black
      srgb(0xFF3B30),  // red
      srgb(0x30D158),  // green
      srgb(0xFF9F0A),  // yellow
      srgb(0x0A84FF),  // blue
      srgb(0xBF5AF2),  // magenta
      srgb(0x64D2FF),  // cyan
      srgb(0xEBEBF5),  // white
    ],
    bright: [
      srgb(0x636366),
      srgb(0xFF6961),
      srgb(0x4ADE80),
      srgb(0xFFD60A),
      srgb(0x409CFF),
      srgb(0xDA8FFF),
      srgb(0x8BDEFF),
      srgb(0xFFFFFF),
    ])

  /// A light theme: the dark theme's hues, taken down in lightness until
  /// each one reads as text on this background (4.5:1), not just as colour.
  ///
  /// The vivid system hues are drawn for a dark ground; on near-white the
  /// bright green and yellow fall under 2:1 and a build log printed in them
  /// cannot be read. Both rows sit in the band that still passes, so `bright`
  /// is the lighter, more saturated end (about 4.6:1) and `normal` the deeper
  /// one (about 6:1). Yellow becomes amber, then gold: a yellow dark enough
  /// to read is olive, and amber kept next to red would be the same colour.
  ///
  /// White and bright white cannot be white here and still be seen. They
  /// stay greys that keep the order black, bright black, white, bright
  /// white getting lighter, so a program that paints a bright-white bar
  /// under black text still gets a light bar with dark text on it. Bright
  /// white is the one slot below 4.5:1 — 3.1:1, readable but quiet.
  public static let light = Palette(
    background: srgb(0xFBFBFC),
    foreground: srgb(0x1F2129),
    cursor: srgb(0x0A84FF),
    normal: [
      srgb(0x1C1C1E),  // black
      srgb(0xC50006),  // red
      srgb(0x037027),  // green
      srgb(0x8B5402),  // yellow
      srgb(0x015FBD),  // blue
      srgb(0x9429C4),  // magenta
      srgb(0x03688F),  // cyan
      srgb(0x6E6E73),  // white
    ],
    bright: [
      srgb(0x48484A),
      srgb(0xE41212),
      srgb(0x06852F),
      srgb(0x9A6903),
      srgb(0x0471DD),
      srgb(0xA740D9),
      srgb(0x087BA8),
      srgb(0x8E8E93),
    ])

  func color(_ color: CellColor) -> Color {
    switch color {
    case .named(let name): named(name)
    case .indexed(let index): indexed(index)
    case .rgb(let red, let green, let blue):
      Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
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
        .sRGB, red: level(value / 36), green: level((value / 6) % 6), blue: level(value % 6))
    default:
      let grey = Double(8 + (Int(index) - 232) * 10) / 255
      return Color(.sRGB, red: grey, green: grey, blue: grey)
    }
  }
}

extension Palette {
  /// `#RRGGBB` in sRGB. `Color(red:green:blue:)` is not that space on every
  /// OS, and a hue that drifts is a different colour than the one named.
  fileprivate static func srgb(_ hex: UInt32) -> Color {
    Color(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }

  /// Which palette a setting and an environment add up to.
  ///
  /// One place, because two would drift: the surface draws with this and the
  /// session tells the far side about it, and a screen drawn light while the
  /// far side was told "dark" is worse than either mistake alone.
  public static func chosen(setting: String, scheme: ColorScheme) -> Palette {
    let dark = setting == "dark" || (setting == "system" && scheme == .dark)
    return dark ? .dark : .light
  }

  /// This palette in the form the far side is told it.
  ///
  /// Only for answering colour queries. What the engine reports is still
  /// names; this is what those names look like here (spec §12).
  public var remoteForm: TerminalPalette {
    TerminalPalette(
      foreground: Palette.channels(foreground),
      background: Palette.channels(background),
      cursor: Palette.channels(cursor),
      ansi: (normal + bright).map(Palette.channels))
  }

  /// A drawn colour as three bytes.
  ///
  /// Resolved through the platform's colour type rather than kept alongside
  /// as numbers: some of these are the system's own blue and grey, which
  /// only the system can turn into channels.
  private static func channels(_ color: Color) -> TerminalColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    #if os(macOS)
      let native = NSColor(color).usingColorSpace(.sRGB) ?? .black
      native.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    #else
      UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    #endif
    func byte(_ value: CGFloat) -> UInt8 {
      UInt8((value * 255).rounded().clamped(to: 0...255))
    }
    return TerminalColor(red: byte(red), green: byte(green), blue: byte(blue))
  }
}

extension CGFloat {
  fileprivate func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
