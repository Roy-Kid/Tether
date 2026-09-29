import CryptoKit
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

  // MARK: - System ssh's known_hosts

  static let blob = Data("a host key".utf8)
  static let other = Data("another host key".utf8)
  static func system(_ text: String) -> SystemKnownHosts { SystemKnownHosts(text) }
  static func seen(_ host: String = "lab.example", port: UInt16 = 22, key: Data = blob) -> HostIdentity {
    HostIdentity(host: host, port: port, algorithm: "ssh-ed25519", fingerprint: SystemKnownHosts.fingerprint(key))
  }

  /// A host ssh has been reaching for years is not a stranger.
  @Test("a key system ssh recorded is trusted")
  func systemTrusted() {
    let file = Self.system("lab.example,10.0.0.4 ssh-ed25519 \(Self.blob.base64EncodedString()) ada@mac\n")
    #expect(file.verdict(for: Self.seen()) == .trusted)
    #expect(file.verdict(for: Self.seen("10.0.0.4")) == .trusted)
    #expect(file.verdict(for: Self.seen("elsewhere.example")) == nil)
  }

  /// `[host]:port` for anything but 22, hashed names, and wildcards.
  @Test("ports, hashed names and patterns are read the way ssh writes them")
  func systemForms() {
    let key = Self.blob.base64EncodedString()
    #expect(Self.system("[lab.example]:2222 ssh-ed25519 \(key)").verdict(for: Self.seen(port: 2222)) == .trusted)
    #expect(Self.system("lab.example ssh-ed25519 \(key)").verdict(for: Self.seen(port: 2222)) == nil)
    let salt = Data("0123456789abcdefghij".utf8)
    let hash = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data("lab.example".utf8), using: SymmetricKey(data: salt)))
    let hashed = "|1|\(salt.base64EncodedString())|\(hash.base64EncodedString()) ssh-ed25519 \(key)"
    #expect(Self.system(hashed).verdict(for: Self.seen()) == .trusted)
    #expect(Self.system(hashed).verdict(for: Self.seen("other.example")) == nil)
    #expect(Self.system("*.example,!db.example ssh-ed25519 \(key)").verdict(for: Self.seen()) == .trusted)
    #expect(Self.system("*.example,!db.example ssh-ed25519 \(key)").verdict(for: Self.seen("db.example")) == nil)
  }

  /// The same alarm ssh would raise, not a fresh first sighting.
  @Test("a key that differs from ssh's record is a changed key")
  func systemChanged() {
    let file = Self.system("lab.example ssh-ed25519 \(Self.other.base64EncodedString())\n")
    guard case .changed(let recorded)? = file.verdict(for: Self.seen()) else {
      Issue.record("a different key of the same kind must be reported as changed")
      return
    }
    #expect(recorded.source == "known_hosts")
    #expect(recorded.fingerprint == SystemKnownHosts.fingerprint(Self.other))
    #expect(Self.system("lab.example ssh-rsa \(Self.other.base64EncodedString())").verdict(for: Self.seen()) == nil,
      "a key of another kind is not a contradiction; ssh would ask")
    guard case .changed? = Self.system("@revoked lab.example ssh-ed25519 \(Self.blob.base64EncodedString())").verdict(for: Self.seen()) else {
      Issue.record("a revoked key must never be trusted")
      return
    }
  }

  /// This app's own pin decides first; ssh's record only fills the gap.
  @Test("the app's own pin outranks ssh's record")
  func ownPinFirst() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    let known = KnownHosts(location: location)
    let file = Self.system("lab.example ssh-ed25519 \(Self.other.base64EncodedString())\n")
    known.remember(Self.seen())
    #expect(known.question(for: Self.seen(), system: file) == nil)
    guard case .unknown? = known.question(for: Self.seen("fresh.example"), system: file) else {
      Issue.record("an endpoint neither knows is unknown")
      return
    }
  }

  /// ssh treats a revoked key as revoked, whatever was accepted before.
  @Test("a key ssh revoked outranks the app's own pin")
  func revokedOutranksPin() {
    let location = temporaryFile("known_hosts.json")
    defer { removeDirectory(of: location) }
    let known = KnownHosts(location: location)
    known.remember(Self.seen())
    let file = Self.system("@revoked lab.example ssh-ed25519 \(Self.blob.base64EncodedString())\n")
    guard case .changed? = known.question(for: Self.seen(), system: file) else {
      Issue.record("a revoked key must not be trusted")
      return
    }
  }
}
