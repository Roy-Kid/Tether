import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The visual vocabulary, in one place.
///
/// Three surfaces, not one: a terminal client is read for hours, and the
/// depth is what keeps a dense host list from reading as a wall. The terminal
/// itself sits *below* the window background rather than above it — the
/// content is the hole in the chrome, not a card on top of it.
enum Theme {
  // Semantic, not literal. Both platforms already have names for "the
  // surface a window sits on" and "the surface content sits on", and they
  // are the names that follow the person's appearance settings, their
  // increased-contrast setting and their accent colour. Hard-coding hexes
  // here would opt out of all three.
  #if os(macOS)
    static let window = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .controlBackgroundColor)
    static let raised = Color(nsColor: .textBackgroundColor)
    static let stroke = Color(nsColor: .separatorColor)
    static let terminal = Color(nsColor: .textBackgroundColor)
  #else
    // A phone's grouped background is the one a `List` draws on, which is
    // what the sidebar becomes when the split view collapses.
    static let window = Color(uiColor: .systemGroupedBackground)
    static let sidebar = Color(uiColor: .secondarySystemBackground)
    static let raised = Color(uiColor: .systemBackground)
    static let stroke = Color(uiColor: .separator)
    static let terminal = Color(uiColor: .systemBackground)
  #endif

  static let text = Color.primary
  static let subtle = Color.secondary
  static let accent = Color.accentColor
  static let danger = Color.red

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

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}


// There is deliberately no `toolbarIconOnly()` helper here.
//
// `labelStyle` inherits down the whole view tree, so applying it once at the
// container was not a convenience — it stripped the text from every `Label`
// below it, and the tab strip lost its titles: a row of identical terminal
// icons with no way to tell one session from another. Each button says
// `.labelStyle(.iconOnly)` for itself, where the effect is visible.
