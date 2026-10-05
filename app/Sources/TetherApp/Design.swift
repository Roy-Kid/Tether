import SwiftUI
import TetherUI

// The shared vocabulary — `Theme`, `UIStyle`, `ChromeButtonStyle` — lives in
// TetherUI, where a plugin's chrome can reach it too. What is left here
// belongs to this window alone.

extension Theme {
  /// The eight tints a host tile can take.
  ///
  /// Assigned from the name rather than chosen, so the same host is the
  /// same colour on every machine and a person navigates by colour before
  /// they read the label — which is the whole reason the tile exists.
  static let tiles: [Color] = [
    Color(hex: 0x4C8DFF), Color(hex: 0x30A46C), Color(hex: 0xE5484D),
    Color(hex: 0xF5A524), Color(hex: 0x8E4EC6), Color(hex: 0x00A2C7),
    Color(hex: 0xD6409F), Color(hex: 0x6E8894),
  ]

  static func tile(for name: String) -> Color {
    // A sum of scalars, not `hashValue`: Swift's hashing is seeded per
    // process, so a hash here would recolour every host on every launch.
    // Unsigned throughout: the sum wraps, and `abs` on a wrapped
    // `Int.min` traps rather than returning a magnitude.
    let sum = name.unicodeScalars.reduce(UInt(0)) { $0 &+ UInt($1.value) }
    return tiles[Int(sum % UInt(tiles.count))]
  }
}

enum Chrome {
  static let tab: CGFloat = 36
  static let status: CGFloat = 24
  static let trafficLights: CGFloat = 76
  static let margin: CGFloat = 12
  static let tabTitleWidth: CGFloat = 180
  static let tabSidebarMin: CGFloat = 180
  static let tabSidebarIdeal: CGFloat = 220
  static let tabSidebarMax: CGFloat = 320
  /// The trailing column beside the terminal. Matches the design mock's
  /// 280pt inspector and the old `inspectorColumnWidth` range.
  static let inspectorMin: CGFloat = 240
  static let inspectorIdeal: CGFloat = 280
  static let inspectorMax: CGFloat = 480
  /// Height of the native titlebar the content draws under on a Mac.
  static let titlebar: CGFloat = 28
  static let windowMinWidth: CGFloat = 760
  static let windowMinHeight: CGFloat = 460
  static let settingsMinWidth: CGFloat = 660
  static let settingsMinHeight: CGFloat = 500
  /// Sidebar column. The section name sits beside the tinted mark.
  static let settingsSidebarMin: CGFloat = 168
  static let settingsSidebarIdeal: CGFloat = 184
  static let settingsSidebarMax: CGFloat = 210
  static let editorWidth: CGFloat = 440
  static let editorHeight: CGFloat = 480
  static let swatchWidth: CGFloat = 76
  static let swatchHeight: CGFloat = 18
  static let ribbonThickness: CGFloat = 9
  static let windowWidth: CGFloat = 1100
  static let windowHeight: CGFloat = 700
  static let settingsWidth: CGFloat = 700
  static let settingsHeight: CGFloat = 540
}
