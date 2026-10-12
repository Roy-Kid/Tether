import Foundation
import Testing
import Tether

@testable import TetherUI

/// Every colour a program can name has to be readable on the background it
/// is drawn over, in both themes. Measured on `remoteForm` — the bytes the
/// far side is told — so what is checked is what is drawn.
@Suite struct PaletteContrastTests {
  /// WCAG's body-text floor.
  static let text = 4.5
  /// WCAG's floor for something that only has to be seen.
  static let seen = 3.0

  /// Slots held to less than `text`, and why. Index into `ansi`: 0–7 normal,
  /// 8–15 bright. Anything not here is held to `text`.
  static let exceptions: [String: [Int: Double]] = [
    // Black is a background colour on a dark ground; text in it is meant
    // to vanish. Bright black is the dim grey for what should recede.
    "dark": [0: 0, 8: seen],
    // Bright white on near-white can be light or legible, not both. It
    // stays the lightest grey of the four so it still sorts above white.
    "light": [15: seen],
  ]

  @Test(arguments: [("dark", Palette.dark), ("light", Palette.light)])
  func everySlotClearsItsFloor(name: String, palette: Palette) {
    let form = palette.remoteForm
    #expect(ratio(form.foreground, form.background) >= Self.text, "\(name) foreground")
    #expect(form.ansi.count == 16)
    for (index, slot) in form.ansi.enumerated() {
      let floor = Self.exceptions[name]?[index] ?? Self.text
      let measured = ratio(slot, form.background)
      #expect(measured >= floor, "\(name) slot \(index): \(measured) < \(floor)")
    }
  }

  /// Bright is a different colour from normal, and on a light ground the
  /// lighter of the two — otherwise asking for bright changes nothing.
  @Test func lightBrightIsLighterThanNormal() {
    let ansi = Palette.light.remoteForm.ansi
    for index in 1..<8 {
      #expect(
        luminance(ansi[index + 8]) > luminance(ansi[index]),
        "light bright slot \(index + 8) is not lighter than \(index)")
    }
  }

  private func ratio(_ one: TerminalColor, _ other: TerminalColor) -> Double {
    let (a, b) = (luminance(one), luminance(other))
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// WCAG relative luminance of an sRGB colour.
  private func luminance(_ color: TerminalColor) -> Double {
    func linear(_ byte: UInt8) -> Double {
      let value = Double(byte) / 255
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red) + 0.7152 * linear(color.green)
      + 0.0722 * linear(color.blue)
  }
}
