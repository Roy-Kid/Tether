import Foundation
import Testing
@testable import TetherApp
import struct TetherApp.Host

/// One library, fed by a Mac's `~/.ssh/config`, against real files. The file
/// is only ever read: whatever happens in Tether, it is byte for byte what the
/// person wrote.
@MainActor
@Suite("SSH configuration into the library")
struct HostImportTests {
  static let original = """
    # The cluster
    Host lab
      HostName login.example.org
      User ada
      ControlMaster auto
      IdentityFile ~/.ssh/personal

    Host *
      ServerAliveInterval 30
    """

  static func mac(_ text: String = original, secrets: MemorySecrets = MemorySecrets()) throws -> (HostStore, URL) {
    let location = temporaryFile("config")
    try text.write(to: location, atomically: true, encoding: .utf8)
    let store = HostStore(location: location, secrets: secrets, credentials: DeviceCredentialStore(secrets: MemorySecrets()))
    return (store, location)
  }

  static func edit(_ location: URL, _ text: String, _ store: HostStore) throws {
    try text.write(to: location, atomically: true, encoding: .utf8)
    store.reload()
    store.reconcile()
  }

  /// Nothing but the person's own file, in the directory Tether reads it from.
  static func untouched(_ location: URL) throws -> Bool {
    let files = try FileManager.default.contentsOfDirectory(atPath: location.deletingLastPathComponent().path)
      .filter { !$0.hasPrefix("config.sqlite") }
    return try String(contentsOf: location, encoding: .utf8) == original && files == ["config"]
  }

  /// The file's hosts join the library — with their key, their saved
  /// password, the ControlMaster this Mac's ssh holds.
  @Test func theFilesHostsJoinTheLibrary() throws {
    let secrets = MemorySecrets()
    try secrets.remember("saved", for: Host(id: Host.id(forAlias: "lab"), label: "lab", hostname: "login.example.org", port: 22, username: "ada"))
    let (store, location) = try Self.mac(secrets: secrets)
    defer { removeDirectory(of: location) }

    let lab = try #require(store.hosts.first)
    #expect(store.hosts.count == 1)
    #expect(lab.isManaged)
    #expect(lab.keyPath == "~/.ssh/personal")
    #expect(lab.allowsMasterReuse)
    #expect(try secrets.password(for: lab.passwordID) == "saved")
    #expect(try Self.untouched(location))
  }

  @Test func aHostTetherCannotRouteIsStillAHost() throws {
    let (store, location) = try Self.mac("Host inside\n  HostName 10.0.0.9\n  ProxyJump bastion\n")
    defer { removeDirectory(of: location) }
    #expect(store.hosts.first?.routeProblem?.contains("proxyjump") == true)
  }

  /// The library is the source of truth: an edit in Tether is the host's
  /// new state, the file is not touched, and reading the file again does not
  /// undo it.
  @Test func anEditInTetherStaysInTether() throws {
    let (store, location) = try Self.mac()
    defer { removeDirectory(of: location) }
    var lab = try #require(store.hosts.first)
    lab.hostname = "gpu.example.org"
    #expect(store.save(lab))
    store.reload()
    store.reconcile()
    #expect(store.hosts.first?.hostname == "gpu.example.org")
    #expect(try Self.untouched(location))
  }

  @Test func anEditedStanzaUpdatesItsHost() throws {
    let (store, location) = try Self.mac()
    defer { removeDirectory(of: location) }
    let id = try #require(store.hosts.first?.id)
    try store.update { $0.records[id]?.dirty = false }
    try Self.edit(location, Self.original.replacingOccurrences(of: "login.example.org", with: "gpu.example.org"), store)
    #expect(store.hosts.first?.hostname == "gpu.example.org")
    #expect(store.snapshot.records[id]?.dirty == true, "on its way to every device")
    #expect(store.hosts.first?.connectionProblem == nil, "this Mac's own file needs no review here")
  }

  @Test func aStanzaTakenOutLeavesItsHost() throws {
    let (store, location) = try Self.mac()
    defer { removeDirectory(of: location) }
    try Self.edit(location, "Host *\n  ServerAliveInterval 30\n", store)
    #expect(store.hosts.map(\.label) == ["lab"])
  }

  /// Deleted in Tether, it stays deleted, though its stanza is still there —
  /// and the file is not touched.
  @Test func aHostDeletedInTetherStaysDeleted() throws {
    let (store, location) = try Self.mac()
    defer { removeDirectory(of: location) }
    store.delete(try #require(store.hosts.first))
    store.reload()
    store.reconcile()
    #expect(store.hosts.isEmpty)
    #expect(try Self.untouched(location))
  }

  /// Two Macs adding the same stanza before they synchronize add one host.
  @Test func twoMacsAddTheSameHost() throws {
    let (first, a) = try Self.mac()
    defer { removeDirectory(of: a) }
    let (second, b) = try Self.mac()
    defer { removeDirectory(of: b) }
    #expect(first.hosts.first?.id == second.hosts.first?.id)
  }

  @Test func aRenamedStanzaKeepsItsHost() throws {
    let (store, location) = try Self.mac()
    defer { removeDirectory(of: location) }
    let id = try #require(store.hosts.first?.id)
    try Self.edit(location, Self.original.replacingOccurrences(of: "Host lab", with: "Host lab-gpu"), store)
    #expect(store.hosts.map(\.label) == ["lab-gpu"])
    #expect(store.hosts.first?.id == id)
  }
}
