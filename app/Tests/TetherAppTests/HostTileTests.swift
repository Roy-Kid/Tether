import Foundation
import Testing
import TetherUI

@testable import TetherApp

import struct TetherApp.Host

/// A host's tint is its glyph, drawn on the list's own background.
@Suite("Host tile")
struct HostTileTests {
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
}
