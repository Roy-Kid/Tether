import AppKit
import Foundation
import Testing
import TetherUI

@testable import TetherApp

import struct TetherApp.Host

/// A host's tint is its glyph, drawn on the list's own background.
@Suite("Host tile")
struct HostTileTests {
  /// The grounds a host row is drawn on, lightest to darkest in each
  /// appearance: a plain row, a grouped list, and roughly where a Mac's
  /// translucent sidebar settles. The last of each is the hard case.
  static let lightGrounds: [UInt32] = [0xFFFFFF, 0xF2F2F7, 0xE5E5EA]
  static let darkGrounds: [UInt32] = [0x000000, 0x1C1C1E, 0x2C2C2E, 0x323232]
  /// WCAG's floor for a mark that has to be seen rather than read.
  static let seen = 3.0

  @Test("every tint is seen on every ground of its own appearance")
  func contrast() {
    for (index, tint) in Theme.tileTints.enumerated() {
      for ground in Self.lightGrounds {
        let measured = ratio(tint.light, ground)
        #expect(measured >= Self.seen, "tint \(index) light on \(hex(ground)): \(measured)")
      }
      for ground in Self.darkGrounds {
        let measured = ratio(tint.dark, ground)
        #expect(measured >= Self.seen, "tint \(index) dark on \(hex(ground)): \(measured)")
      }
    }
  }

  @Test("the drawn colour is the half that matches the appearance")
  func resolves() {
    for tint in Theme.tileTints {
      #expect(resolved(tint, .aqua) == tint.light)
      #expect(resolved(tint, .darkAqua) == tint.dark)
    }
  }

  @Test("a labelled host keeps the colour its label always gave it")
  func labelled() {
    let host = Host(label: "Arrhenius", hostname: "login.example.org", port: 22, username: "ada")
    let sum = "Arrhenius".unicodeScalars.reduce(UInt(0)) { $0 &+ UInt($1.value) }
    #expect(Theme.tileIndex(for: host) == Int(sum % UInt(Theme.tileTints.count)))
    var moved = host
    moved.hostname = "other.example.org"
    #expect(Theme.tileIndex(for: moved) == Theme.tileIndex(for: host))
  }

  @Test("unlabelled hosts take their colour from their id, the same on every device")
  func unlabelled() throws {
    let ids = try [
      "6F9619FF-8B86-D011-B42D-00C04FC964FF", "0E984725-C51C-4BF4-9960-E1C80E27ABA0",
      "A3BB189E-8BF9-3888-9912-ACE4E6543002", "123E4567-E89B-12D3-A456-426614174000",
    ].map { try #require(UUID(uuidString: $0)) }
    let hosts = ids.map { Host(id: $0, label: "", hostname: "example.org", port: 22, username: "ada") }
    let indices = hosts.map(Theme.tileIndex(for:))
    #expect(Set(indices).count > 1, "every unlabelled host is one colour again: \(indices)")
    // Another device decodes the same record into a host with the same id.
    let synced = Host(id: ids[0], label: "", hostname: "elsewhere.org", port: 2222, username: "bo")
    #expect(Theme.tileIndex(for: synced) == indices[0])
  }

  private func resolved(_ tint: TileTint, _ name: NSAppearance.Name) -> UInt32? {
    var result: UInt32?
    NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
      guard let color = NSColor(tint.color).usingColorSpace(.sRGB) else { return }
      func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
      result = byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
    }
    return result
  }

  private func hex(_ value: UInt32) -> String { String(format: "%06X", value) }

  private func ratio(_ one: UInt32, _ other: UInt32) -> Double {
    let (a, b) = (luminance(one), luminance(other))
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// WCAG relative luminance of `0xRRGGBB` in sRGB.
  private func luminance(_ hex: UInt32) -> Double {
    func linear(_ shift: UInt32) -> Double {
      let value = Double((hex >> shift) & 0xFF) / 255
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
  }
}
