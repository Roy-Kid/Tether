import SwiftUI
import TetherUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

// The shared vocabulary — `Theme`, `UIStyle`, `ChromeButtonStyle` — lives in
// TetherUI, where a plugin's chrome can reach it too. What is left here
// belongs to this window alone.

/// One host tint, as it is drawn on a light list and on a dark one.
///
/// The tint is the glyph itself, sitting on the list's own background, so
/// each half is chosen against that background: a mark has to be seen
/// (3:1), and a single set of hexes cannot be — the amber that glows on a
/// dark sidebar disappears on a light one, and the violet the other way.
struct TileTint: Equatable {
  let light: UInt32
  let dark: UInt32

  var color: Color {
    #if os(macOS)
      Color(
        nsColor: NSColor(name: nil) { appearance in
          let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          return TileTint.native(dark ? self.dark : self.light)
        })
    #else
      Color(uiColor: UIColor { traits in
        TileTint.native(traits.userInterfaceStyle == .dark ? self.dark : self.light)
      })
    #endif
  }

  #if os(macOS)
    private static func native(_ hex: UInt32) -> NSColor {
      NSColor(srgbRed: channel(hex, 16), green: channel(hex, 8), blue: channel(hex, 0), alpha: 1)
    }
  #else
    private static func native(_ hex: UInt32) -> UIColor {
      UIColor(red: channel(hex, 16), green: channel(hex, 8), blue: channel(hex, 0), alpha: 1)
    }
  #endif

  private static func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat {
    CGFloat((hex >> shift) & 0xFF) / 255
  }
}

extension Theme {
  /// The eight tints a host tile can take, in a fixed order — the order is
  /// what a host's identity indexes, so it never changes.
  ///
  /// Assigned rather than chosen, so the same host is the same colour on
  /// every machine and a person navigates by colour before they read the
  /// label — which is the whole reason the tile exists.
  static let tileTints: [TileTint] = [
    TileTint(light: 0x3776E6, dark: 0x4C8DFF),  // blue
    TileTint(light: 0x088C57, dark: 0x30A46C),  // green
    TileTint(light: 0xDD4047, dark: 0xF75A5C),  // red
    TileTint(light: 0xA96E04, dark: 0xF5A524),  // amber
    TileTint(light: 0x8E4EC6, dark: 0xB273EE),  // violet
    TileTint(light: 0x0A85A4, dark: 0x00A2C7),  // cyan
    TileTint(light: 0xD33D9C, dark: 0xED56B3),  // pink
    TileTint(light: 0x657E8A, dark: 0x7994A0),  // slate
  ]

  static let tiles: [Color] = tileTints.map(\.color)

  static func tile(for host: Host) -> Color { tiles[tileIndex(for: host)] }

  /// Which tint a host takes.
  ///
  /// The label, because that is what every host already had its colour
  /// from and recolouring a library someone has learned is worse than the
  /// collision it fixes. A host with no label falls back to its id — the
  /// identifier its record syncs under, so it is the same on every device —
  /// rather than to the empty string every unlabelled host would share.
  static func tileIndex(for host: Host) -> Int {
    let key = host.label.isEmpty ? host.id.uuidString : host.label
    // A sum of scalars, not `hashValue`: Swift's hashing is seeded per
    // process, so a hash here would recolour every host on every launch.
    // Unsigned throughout: the sum wraps, and `abs` on a wrapped
    // `Int.min` traps rather than returning a magnitude.
    let sum = key.unicodeScalars.reduce(UInt(0)) { $0 &+ UInt($1.value) }
    return Int(sum % UInt(tileTints.count))
  }
}

enum Chrome {
  /// The titlebar row. Traffic lights are centred in the 32pt system
  /// titlebar; a shorter strip leaves a band of window colour between
  /// the open tab and the terminal.
  #if os(macOS)
    static let tab: CGFloat = 32
  #else
    static let tab: CGFloat = 28
  #endif
  /// A sidebar tab stacks a title and a subtitle, so its row stays taller.
  static let tabSidebarRow: CGFloat = 36
  static let status: CGFloat = 24
  static let trafficLights: CGFloat = 76
  static let margin: CGFloat = 12
  static let tabTitleWidth: CGFloat = 144
  /// Top corners of a titlebar tab. The bottom stays square so the open
  /// terminal continues into the grid instead of sitting under a card.
  static let tabRadius: CGFloat = 16
  /// The close mark. The control that holds it stays `UIStyle.Mark.icon` wide.
  static let tabClose: CGFloat = 9
  static let tabSidebarMin: CGFloat = 180
  static let tabSidebarIdeal: CGFloat = 220
  static let tabSidebarMax: CGFloat = 320
  /// The trailing column beside the terminal. Matches the design mock's
  /// 280pt inspector and the old `inspectorColumnWidth` range.
  static let inspectorMin: CGFloat = 240
  static let inspectorIdeal: CGFloat = 280
  static let inspectorMax: CGFloat = 480
  /// Height of the native titlebar the content draws under on a Mac.
  #if os(macOS)
    static let titlebar: CGFloat = 32
  #else
    static let titlebar: CGFloat = 28
  #endif
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
