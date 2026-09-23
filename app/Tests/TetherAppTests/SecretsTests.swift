import Foundation
import Testing

@testable import TetherApp

// `Foundation` exports a `Host` of its own, and qualifying by module name does
// not help here — the app's `@main` type is also called `TetherApp`. Importing
// the one type by name settles it.
import struct TetherApp.Host

/// What the app does around a keychain.
///
/// `Keychain` itself is not exercised: it is the system's, and asking for it
/// from a unit test means a prompt on a developer's machine and a refusal on
/// a build server. What is testable — and what has actually gone wrong in
/// clients before — is the bookkeeping either side of it: a password kept for
/// a host that no longer exists, a flag that says "remembered" with nothing
/// stored, a list drawn from an entry whose host was deleted.
@MainActor
@Suite("Secrets")
struct SecretsTests {
  static func host(_ label: String = "lab") -> Host {
    Host(label: label, hostname: "10.0.0.4", port: 22, username: "scientist", keyPath: nil)
  }

  @Test("a password is kept under the host's identity, not its address")
  func identity() throws {
    let secrets = MemorySecrets()
    var host = Self.host()
    try secrets.remember("hunter2", for: host)

    // Renaming a host, moving it to another port, pointing it at a new
    // address: all the same saved host, and a person who said "remember this"
    // did not mean "until the address changes".
    host.label = "lab (rebuilt)"
    host.hostname = "10.0.0.5"
    host.port = 2222

    #expect(try secrets.password(for: host.id) == "hunter2")
  }

  @Test("nothing stored is not an error")
  func absence() throws {
    let secrets = MemorySecrets()
    #expect(try secrets.password(for: UUID()) == nil)
    #expect(try secrets.saved().isEmpty)
  }

  @Test("the list carries an address to recognise and no password to read")
  func listing() throws {
    let secrets = MemorySecrets()
    let host = Self.host()
    try secrets.remember("hunter2", for: host)

    let saved = try secrets.saved()
    #expect(saved.map(\.id) == [host.id])
    #expect(saved.first?.label.contains("scientist@10.0.0.4") == true)
  }

  @Test("forgetting is idempotent")
  func forgetting() throws {
    let secrets = MemorySecrets()
    let host = Self.host()
    try secrets.remember("hunter2", for: host)

    try secrets.forget(host.id)
    try secrets.forget(host.id)
    #expect(try secrets.password(for: host.id) == nil)
  }

  /// A keychain that refuses must not be mistaken for an empty one. The
  /// settings screen shows the error instead of the reassuring "No passwords
  /// are saved", which is the one thing it must never say by accident.
  @Test("a refusal is an error, not an empty list")
  func refusal() {
    let secrets = MemorySecrets()
    secrets.refusing = true
    #expect(throws: SecretError.self) { try secrets.saved() }
    #expect(throws: SecretError.self) { try secrets.password(for: UUID()) }
  }
}
