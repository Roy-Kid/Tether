import Foundation
import Tether
import Testing

@testable import TetherApp

/// The record of which host keys someone accepted.
///
/// This is the app's half of strict host verification (spec §18). The
/// dangerous case is not the unknown host — it is the *changed* key, which is
/// either an administrator rotating it or someone standing in the middle, and
/// only the person can tell which. A bug that turned that question into
/// silence would be invisible until it mattered.
@MainActor
@Suite("Known hosts")
struct KnownHostsTests {
  static func identity(
    host: String = "10.0.0.4", port: UInt16 = 22, fingerprint: String = "SHA256:aaa"
  ) -> HostIdentity {
    HostIdentity(host: host, port: port, algorithm: "ssh-ed25519", fingerprint: fingerprint)
  }

  @Test("a host nobody has seen is asked about")
  func unknown() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    let known = KnownHosts(location: location)

    guard case .unknown = known.question(for: Self.identity()) else {
      Issue.record("a first sighting must be unknown")
      return
    }
  }

  @Test("a key already accepted is not asked about again")
  func remembered() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    let known = KnownHosts(location: location)

    known.remember(Self.identity())
    #expect(known.question(for: Self.identity()) == nil)
  }

  @Test("a key that changed under a host is the question that matters")
  func changed() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    let known = KnownHosts(location: location)

    known.remember(Self.identity(fingerprint: "SHA256:aaa"))

    guard case .changed(let from) = known.question(for: Self.identity(fingerprint: "SHA256:bbb"))
    else {
      Issue.record("a different key for a known endpoint must be reported as changed")
      return
    }
    #expect(from.fingerprint == "SHA256:aaa")
  }

  /// `example.org` and `example.org:22` as two endpoints with one key between
  /// them would mean the mismatch check never fires — the failure would look
  /// like nothing at all.
  @Test("a port is part of what a key belongs to")
  func portIsPartOfTheIdentity() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    let known = KnownHosts(location: location)

    known.remember(Self.identity(port: 22))

    guard case .unknown = known.question(for: Self.identity(port: 2222)) else {
      Issue.record("another port is another endpoint")
      return
    }
    #expect(KnownHosts.endpoint(Self.identity(port: 2222)) == "10.0.0.4:2222")
  }

  @Test("accepting a new key replaces the old one rather than adding to it")
  func rotation() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    let known = KnownHosts(location: location)

    known.remember(Self.identity(fingerprint: "SHA256:aaa"))
    known.remember(Self.identity(fingerprint: "SHA256:bbb"))

    #expect(known.entries.count == 1)
    #expect(known.entries.first?.fingerprint == "SHA256:bbb")
  }

  @Test("forgetting a key means being asked about it again")
  func forgetting() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    let known = KnownHosts(location: location)

    known.remember(Self.identity())
    known.forget(KnownHosts.endpoint(Self.identity()))

    #expect(known.entries.isEmpty)
    guard case .unknown = known.question(for: Self.identity()) else {
      Issue.record("a forgotten key must be unknown again")
      return
    }

    // And it stays forgotten: the settings screen that offers this would be
    // lying if the entry came back on the next launch.
    let reopened = KnownHosts(location: location)
    #expect(reopened.entries.isEmpty)
  }

  @Test("what was accepted survives a relaunch")
  func persistence() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }

    KnownHosts(location: location).remember(Self.identity())

    let reopened = KnownHosts(location: location)
    #expect(reopened.entries.map(\.endpoint) == ["10.0.0.4:22"])
    #expect(reopened.question(for: Self.identity()) == nil)
  }

  /// Losing this file silently would turn every host back into an unknown
  /// one, and a prompt that returns for no reason is a prompt people stop
  /// reading.
  @Test("a damaged file is moved aside, not overwritten")
  func damagedFile() throws {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    try Data("[{".utf8).write(to: location)

    let known = KnownHosts(location: location)
    #expect(known.entries.isEmpty)
    #expect(
      FileManager.default.fileExists(atPath: location.appendingPathExtension("unreadable").path))
  }
}
