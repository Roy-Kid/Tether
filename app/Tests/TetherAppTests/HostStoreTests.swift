import Foundation
import Testing
@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Shared host store")
struct HostStoreTests {
  static func host(_ label: String = "lab") -> Host {
    Host(label: label, hostname: "login.example.org", port: 22, username: "ada")
  }
  @Test func stableIdentityAndLocalBinding() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let secrets = MemorySecrets()
    let store = HostStore(location: location, secrets: secrets)
    var host = Self.host()
    host.keyPath = "~/.ssh/personal"
    #expect(store.save(host, password: "saved"))
    var saved = try #require(store.hosts.first)
    #expect(saved.id == host.id)
    saved.label = "renamed"
    #expect(store.save(saved))
    let reopened = HostStore(location: location, secrets: secrets)
    #expect(reopened.hosts.first?.id == host.id)
    #expect(reopened.hosts.first?.keyPath == "~/.ssh/personal")
    #expect(try secrets.password(for: #require(reopened.hosts.first).passwordID) == "saved")
    #expect(!FileManager.default.fileExists(atPath: location.path))
    let payload = try JSONEncoder().encode(#require(store.snapshot.records[host.id]).profile)
    #expect(!String(decoding: payload, as: UTF8.self).contains(".ssh"))
    #expect(!String(decoding: payload, as: UTF8.self).contains("saved"))
  }
  @Test func explicitAdoptionPreservesOriginal() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let original = "Host lab\n  HostName login.example.org\n  User ada\n  ControlMaster auto\n  IdentityFile ~/.ssh/personal\n"
    try original.write(to: location, atomically: true, encoding: .utf8)
    let secrets = MemorySecrets()
    let store = HostStore(location: location, secrets: secrets)
    let imported = try #require(store.hosts.first)
    try secrets.remember("saved", for: imported)
    #expect(!store.save(imported))
    store.adopt(imported)
    store.adopt(imported)
    #expect(store.hosts.count == 1)
    let managed = try #require(store.hosts.first)
    #expect(managed.isManaged)
    #expect(managed.id != imported.id)
    #expect(try secrets.password(for: managed.passwordID) == "saved")
    #expect(try String(contentsOf: location, encoding: .utf8) == original)
  }
  @Test func unsupportedImportIsVisible() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    try "Host lab\n  HostName login.example.org\n  User ada\n  ProxyJump bastion\n".write(to: location, atomically: true, encoding: .utf8)
    let store = HostStore(location: location, secrets: MemorySecrets())
    store.adopt(try #require(store.hosts.first))
    #expect(store.problem?.contains("proxyjump") == true)
    #expect(store.snapshot.records.isEmpty)
  }
  @Test func synchronizedHostRequiresLocalReviewAndKey() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let store = HostStore(location: location, secrets: MemorySecrets())
    var host = Self.host(); host.keyPath = "~/.ssh/private"
    #expect(store.save(host))
    let profile = try #require(store.snapshot.records[host.id]?.profile)
    let phone = HostStore(location: location.appendingPathExtension("phone"), secrets: MemorySecrets())
    try phone.receive(profile, deleted: false, systemFields: nil)
    #expect(phone.hosts.first?.connectionProblem == "Review authentication settings")
    phone.approve(profile.id)
    #expect(phone.hosts.first?.connectionProblem == IdentityError.missingCredential.localizedDescription)
    #expect(phone.hosts.first?.keyPath == nil)
  }
  @Test func tombstoneSurvivesOfflineEdit() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let store = HostStore(location: location, secrets: MemorySecrets())
    let host = Self.host(); #expect(store.save(host))
    let managed = try #require(store.hosts.first)
    let profile = try #require(managed.profile)
    store.delete(managed)
    try store.receive(profile, deleted: false, systemFields: nil)
    #expect(store.hosts.isEmpty)
    #expect(store.snapshot.records[host.id]?.deleted == true)
    #expect(!store.save(managed))
  }
  @Test func accountLibrariesStaySeparate() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let store = HostStore(location: location, secrets: MemorySecrets())
    #expect(store.save(Self.host()))
    try store.switchAccount("icloud:A")
    #expect(store.hosts.isEmpty)
    store.importLocalLibrary()
    #expect(store.hosts.count == 1)
    try store.switchAccount("icloud:B")
    #expect(store.hosts.isEmpty)
    try store.switchAccount("icloud:A")
    #expect(store.hosts.count == 1)
  }
  @Test func failedKeychainWriteDoesNotSave() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let secrets = MemorySecrets(); secrets.refusing = true
    let store = HostStore(location: location, secrets: secrets)
    #expect(!store.save(Self.host(), password: "secret"))
    #expect(store.hosts.isEmpty)
    #expect(store.problem != nil)
  }
}
