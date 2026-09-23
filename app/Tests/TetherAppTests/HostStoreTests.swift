import Foundation
import Testing

@testable import TetherApp

// `Foundation` exports a `Host` of its own, and qualifying by module name does
// not help here — the app's `@main` type is also called `TetherApp`. Importing
// the one type by name settles it.
import struct TetherApp.Host

/// The host list, which is the person's `~/.ssh/config`.
///
/// Nothing here is about SwiftUI: it is about the state the views read. A
/// view that draws the wrong list is a bug someone sees; a store that loses
/// the list is a bug someone cannot undo — and the list is now a file that
/// `ssh` reads as well, so losing it loses more than this app.
@MainActor
@Suite("Host store")
struct HostStoreTests {
  static func store(_ secrets: MemorySecrets = MemorySecrets()) -> (HostStore, URL) {
    let location = temporaryFile("config")
    return (HostStore(location: location, secrets: secrets), location)
  }

  static func host(_ label: String = "lab") -> Host {
    Host(label: label, hostname: "10.0.0.4", port: 22, username: "scientist", keyPath: nil)
  }

  @Test("saving twice edits rather than duplicates")
  func savingIsIdempotent() throws {
    let (store, location) = Self.store()
    defer { removeDirectory(of: location) }

    store.save(Self.host())
    // Read back rather than reused: the store is a file, and what a person
    // edits is the host the list is showing them.
    var host = try #require(store.hosts.first)
    host.label = "lab (moved)"
    store.save(host)

    #expect(store.hosts.count == 1)
    #expect(store.hosts.first?.label == "lab (moved)")
  }

  @Test("an IdentityFile in the config is the host's key")
  func identityFileBecomesKeyPath() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }

    try """
      Host Arrhenius
          HostName login.example
          User ada

          IdentityFile ~/.ssh/id_arrhenius_mac
          IdentitiesOnly yes
      """.write(to: location, atomically: true, encoding: .utf8)

    let store = HostStore(location: location, secrets: MemorySecrets())
    #expect(store.hosts.first?.keyPath == "~/.ssh/id_arrhenius_mac")
    #expect(store.hosts.first?.offersConfiguredKey == true)
  }

  /// The editor hands over a `blank()` host whose id is random. The password
  /// has to be stored under the stanza name, or the next launch would ask
  /// again for a secret that is sitting in the keychain under a dead id.
  @Test("a password is kept under the stanza name, not the editor's id")
  func passwordFollowsAlias() throws {
    let secrets = MemorySecrets()
    let (store, location) = Self.store(secrets)
    defer { removeDirectory(of: location) }

    var host = Host.blank()
    host.label = "Arrhenius"
    host.hostname = "login.hpc.arrhenius.naiss.se"
    host.username = "jicli594"
    let editorID = host.id
    store.save(host, password: "hunter2")

    let id = Host.id(forAlias: "Arrhenius")
    #expect(try secrets.password(for: id) == "hunter2")
    #expect(try secrets.password(for: editorID) == nil)
    #expect(store.hosts.first?.remembersPassword == true)

    store.save(try #require(store.hosts.first), password: "")
    #expect(try secrets.password(for: id) == nil)
  }

  @Test("what was saved is what comes back")
  func persistence() {
    let (store, location) = Self.store()
    defer { removeDirectory(of: location) }

    var host = Self.host()
    host.keyPath = "/home/scientist/.ssh/id_ed25519"
    store.save(host)

    let reopened = HostStore(location: location, secrets: MemorySecrets())
    let read = reopened.hosts.first

    #expect(reopened.hosts.count == 1)
    #expect(read?.label == "lab")
    #expect(read?.hostname == "10.0.0.4")
    #expect(read?.username == "scientist")
    #expect(read?.keyPath == "/home/scientist/.ssh/id_ed25519")
  }

  /// A host's identity comes from its name in the file, because the file has
  /// nowhere to keep an invented one. Two readings of the same config must
  /// agree about it, or the keychain would be handed a different host on
  /// every launch and a saved password would be unreachable.
  @Test("a host has the same identity every time the file is read")
  func identityIsStable() {
    let (store, location) = Self.store()
    defer { removeDirectory(of: location) }

    store.save(Self.host())
    let first = store.hosts.first?.id
    let reopened = HostStore(location: location, secrets: MemorySecrets())

    #expect(first != nil)
    #expect(reopened.hosts.first?.id == first)
    #expect(Host.id(forAlias: "lab") == first)
  }

  /// The one the file's owner would care about. Anything this app does not
  /// understand has to survive being edited by it.
  @Test("settings this app knows nothing about survive an edit")
  func foreignSettingsSurvive() throws {
    let (store, location) = Self.store()
    defer { removeDirectory(of: location) }

    try """
      Host lab
        HostName 10.0.0.4
        ControlMaster auto
        ControlPath ~/.ssh/cm-%C
      """.write(to: location, atomically: true, encoding: .utf8)

    let store2 = HostStore(location: location, secrets: MemorySecrets())
    var host = try #require(store2.hosts.first)
    host.hostname = "10.0.0.5"
    store2.save(host)

    let written = try String(contentsOf: location, encoding: .utf8)
    #expect(written.contains("ControlMaster auto"))
    #expect(written.contains("ControlPath ~/.ssh/cm-%C"))
    #expect(written.contains("HostName 10.0.0.5"))
    _ = store
  }

  /// A config that cannot be read is left exactly as it is. Starting from an
  /// empty one would mean the next host added replaces the person's whole ssh
  /// configuration, and there is no other copy of it.
  @Test("a file that cannot be read is reported, not replaced")
  func unreadableFile() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    // Not valid UTF-8, which is the one way a text file refuses to be read.
    try Data([0xFF, 0xFE, 0xFF]).write(to: location)

    let store = HostStore(location: location, secrets: MemorySecrets())
    #expect(store.hosts.isEmpty)
    #expect(store.problem != nil)

    store.save(Self.host())
    #expect(try Data(contentsOf: location) == Data([0xFF, 0xFE, 0xFF]))
  }

  /// A deleted host must not leave a password behind: the person deleting it
  /// has no other way to reach the item, and would not know it was there.
  @Test("deleting a host deletes its password")
  func deletingForgets() throws {
    let secrets = MemorySecrets()
    let (store, location) = Self.store(secrets)
    defer { removeDirectory(of: location) }

    let host = Self.host()
    store.save(host)
    try secrets.remember("hunter2", for: host)

    store.delete(host)
    #expect(store.hosts.isEmpty)
    #expect(try secrets.password(for: host.id) == nil)
  }

  /// A person who renames a host did not ask to be asked for its password
  /// again. The name is the identity in an ssh config, so a rename is a new
  /// identity — and the saved password has to follow the machine they meant
  /// rather than the string they changed.
  @Test("renaming a host takes its password with it")
  func renamingCarriesTheSecret() throws {
    let secrets = MemorySecrets()
    let (store, location) = Self.store(secrets)
    defer { removeDirectory(of: location) }

    store.save(Self.host())
    var host = try #require(store.hosts.first)
    try secrets.remember("hunter2", for: host)

    let before = host.id
    host.label = "lab-two"
    store.save(host)

    let renamed = try #require(store.hosts.first)
    #expect(renamed.label == "lab-two")
    #expect(try secrets.password(for: renamed.id) == "hunter2")
    #expect(try secrets.password(for: before) == nil)
    #expect(renamed.remembersPassword)
  }

  /// A keychain that refuses is not a reason to keep the host: the item
  /// survives, and the saved-passwords list in settings is where it shows up.
  @Test("a host is deleted even when the keychain refuses")
  func deletingSurvivesARefusal() {
    let secrets = MemorySecrets()
    let (store, location) = Self.store(secrets)
    defer { removeDirectory(of: location) }

    let host = Self.host()
    store.save(host)
    secrets.refusing = true
    store.delete(host)

    #expect(store.hosts.isEmpty)
  }

  @Test("search matches a label, an address or a user")
  func filtering() {
    let (store, location) = Self.store()
    defer { removeDirectory(of: location) }

    store.save(Host(label: "Lab", hostname: "10.0.0.4", port: 22, username: "ada", keyPath: nil))
    store.save(
      Host(label: "Cluster", hostname: "hpc.example.org", port: 22, username: "grace", keyPath: nil)
    )

    store.search = "hpc"
    #expect(store.filtered.map(\.label) == ["Cluster"])
    store.search = "ADA"
    #expect(store.filtered.map(\.label) == ["Lab"])
    store.search = "   "
    // A query of nothing is not a query: everything the sidebar would show
    // comes back, which is the saved hosts *and* the machine this is running
    // on. Compared against `listed` rather than a number, because whether
    // there is a local row is the platform's answer, not this test's.
    #expect(store.filtered.count == store.listed.count)
    #expect(store.filtered.contains { $0.label == "Lab" })
    #expect(store.filtered.contains { $0.label == "Cluster" })
  }

  @Test("the address a person reads keeps the port only when it is unusual")
  func address() {
    var host = Self.host()
    #expect(host.address == "scientist@10.0.0.4")
    host.port = 2222
    #expect(host.address == "scientist@10.0.0.4:2222")
  }
}
