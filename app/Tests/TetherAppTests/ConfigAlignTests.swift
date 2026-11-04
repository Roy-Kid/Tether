import Foundation
import Testing

@testable import TetherApp

import struct TetherApp.Host

/// The library ahead of `~/.ssh/config`, and the write a person has to agree to.
///
/// What these pin: the question names the hosts that differ; agreeing changes
/// only those hosts' name, address, user and port; a comment, a jump host and
/// a `Host *` stay; an included file is never opened for writing; declining
/// writes nothing.
@MainActor
@Suite("SSH configuration aligned with the library")
struct ConfigAlignTests {
  static let config = "/Users/ada/.ssh/config"

  static func face(_ name: String = "lab", host: String = "10.0.0.9", user: String = "ada", port: UInt16 = 22) -> HostFace {
    HostFace(name: name, hostName: host, user: user, port: port)
  }

  static func entry(_ alias: String = "lab", host: String = "10.0.0.4", user: String? = "ada", port: UInt16? = nil,
    file: String? = config) -> SSHConfig.Entry {
    SSHConfig.Entry(alias: alias, hostName: host, user: user, port: port, identityFile: nil, file: file)
  }

  static func record(label: String = "lab", host: String = "10.0.0.4", user: String = "ada", port: UInt16 = 22,
    deleted: Bool = false) -> SharedHostRecord {
    let profile = HostStore.newProfile(id: UUID(), label: label, hostname: host, username: user, port: port, key: false)
    var record = SharedHostRecord(profile: profile)
    record.deleted = deleted
    return record
  }

  static func plan(_ entries: [SSHConfig.Entry], _ records: [SharedHostRecord],
    links: [String: ImportLink] = [:], keys: [UUID: String] = [:]) -> ConfigAlign.Plan {
    ConfigAlign.plan(.init(
      entries: entries, records: Dictionary(uniqueKeysWithValues: records.map { ($0.profile.id, $0) }),
      links: links, keyPaths: keys, file: config, defaultUser: "ada"))
  }

  @Test("an agreed edit changes the address and leaves the rest of the stanza")
  func editsInPlace() {
    let original = """
      # kept
      Host lab
        # the cluster
        HostName=10.0.0.4
        User ada
        ProxyJump bastion
        IdentityFile ~/.ssh/id_lab

      Host *
        User ada
        ServerAliveInterval 30
      """
    let written = SSHConfigRewrite.applying(
      [ConfigAlign.Edit.update(Self.face(), from: nil)], to: original, defaultUser: "ada")
    let expected = original.replacingOccurrences(of: "10.0.0.4", with: "10.0.0.9")
    #expect(written == expected + (expected.hasSuffix("\n") ? "" : "\n"))
    let parsed = SSHConfig(written)
    #expect(HostFace(parsed.entries[0], defaultUser: "ada") == Self.face())
  }

}

@MainActor
@Suite("Writing the agreed alignment")
struct ConfigAlignWriteTests {
  static func store(_ text: String, name: String = "config") throws -> (HostStore, URL) {
    let location = temporaryFile(name)
    if !text.isEmpty { try text.write(to: location, atomically: true, encoding: .utf8) }
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: DeviceCredentialStore(secrets: MemorySecrets()))
    store.reconcile()
    return (store, location)
  }

  @Test("declining writes nothing, and the same difference is not asked again")
  func decline() throws {
    let (store, location) = try Self.store("Host lab\n  HostName 10.0.0.4\n  User ada\n")
    defer { removeDirectory(of: location) }
    var lab = try #require(store.hosts.first)
    lab.hostname = "10.0.0.9"
    #expect(store.save(lab))
    store.reconcile()

    store.reviewConfiguration()
    let asked = try #require(store.pendingAlignment)
    #expect(asked.message == "lab")
    store.declineConfigurationAlignment()
    #expect(store.pendingAlignment == nil)
    store.reviewConfiguration()
    #expect(store.pendingAlignment == nil)
    #expect(try String(contentsOf: location, encoding: .utf8).contains("10.0.0.4"))
  }

  @Test("agreeing updates the stanza, keeps the jump host, and asks nothing more")
  func agree() throws {
    let original = """
      # kept
      Host lab
        HostName 10.0.0.4
        User ada
        ProxyJump bastion

      Host other
        HostName 10.0.0.5
        User ada
      """
    let (store, location) = try Self.store(original)
    defer { removeDirectory(of: location) }
    var lab = try #require(store.hosts.first { $0.label == "lab" })
    lab.hostname = "10.0.0.9"
    #expect(store.save(lab))
    store.reconcile()
    store.reviewConfiguration()
    store.writeConfigurationAlignment()

    let written = try String(contentsOf: location, encoding: .utf8)
    #expect(written.contains("# kept"))
    #expect(written.contains("HostName 10.0.0.9"))
    #expect(written.contains("ProxyJump bastion"))
    #expect(written.contains("Host other"))
    #expect(store.hosts.first { $0.label == "lab" }?.hostname == "10.0.0.9")
    #expect(store.hosts.first { $0.label == "lab" }?.routeProblem?.contains("proxyjump") == true)
    #expect(store.pendingAlignment == nil)
    store.reviewConfiguration()
    #expect(store.pendingAlignment == nil)
    let files = try FileManager.default.contentsOfDirectory(atPath: location.deletingLastPathComponent().path)
    #expect(!files.contains { $0.contains(".tether-") })
  }

  @Test("a host deleted in Tether is removed from the file only when agreed")
  func removal() throws {
    let (store, location) = try Self.store("Host lab\n  HostName 10.0.0.4\n  User ada\n\nHost *\n  User ada\n")
    defer { removeDirectory(of: location) }
    store.delete(try #require(store.hosts.first))
    #expect(try String(contentsOf: location, encoding: .utf8).contains("Host lab"))
    store.reviewConfiguration()
    store.writeConfigurationAlignment()
    let written = try String(contentsOf: location, encoding: .utf8)
    #expect(!written.contains("Host lab"))
    #expect(written.contains("Host *"))
    #expect(store.hosts.isEmpty)
  }

  @Test("a renamed host stays one host")
  func rename() throws {
    let (store, location) = try Self.store("Host lab\n  HostName 10.0.0.4\n  User ada\n  ProxyJump bastion\n")
    defer { removeDirectory(of: location) }
    var lab = try #require(store.hosts.first)
    let id = lab.id
    lab.label = "gpu"
    #expect(store.save(lab))
    store.reconcile()
    store.reviewConfiguration()
    store.writeConfigurationAlignment()
    #expect(store.hosts.map(\.id) == [id])
    #expect(store.hosts.map(\.label) == ["gpu"])
    let written = try String(contentsOf: location, encoding: .utf8)
    #expect(written.contains("Host gpu"))
    #expect(!written.contains("Host lab"))
    #expect(written.contains("ProxyJump bastion"))
  }

  @Test("an included file is not modified")
  func includeIsUntouched() throws {
    let directory = temporaryFile("config").deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let included = directory.appending(path: "lab.conf")
    let includeText = "Host lab\n  HostName 10.0.0.4\n  User ada\n  ProxyJump bastion\n"
    try includeText.write(to: included, atomically: true, encoding: .utf8)
    let config = directory.appending(path: "config")
    try "Include lab.conf\n".write(to: config, atomically: true, encoding: .utf8)
    let store = HostStore(location: config, secrets: MemorySecrets(), credentials: DeviceCredentialStore(secrets: MemorySecrets()))
    store.reconcile()
    var lab = try #require(store.hosts.first)
    lab.hostname = "10.0.0.9"
    #expect(store.save(lab))
    store.reconcile()
    store.reviewConfiguration()
    #expect(store.pendingAlignment?.edits.count == 1)
    store.writeConfigurationAlignment()
    #expect(try String(contentsOf: included, encoding: .utf8) == includeText)
    #expect(store.hosts.first?.hostname == "10.0.0.9")
    #expect(store.pendingAlignment == nil)
  }

  @Test("a library host is added when the file does not exist yet")
  func createsTheFile() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: DeviceCredentialStore(secrets: MemorySecrets()))
    #expect(store.save(Host(label: "gpu", hostname: "10.0.0.8", port: 22, username: "ada", keyPath: nil)))
    store.reviewConfiguration()
    store.writeConfigurationAlignment()
    let written = try String(contentsOf: location, encoding: .utf8)
    #expect(written.contains("Host gpu"))
    #expect(written.contains("HostName 10.0.0.8"))
    #expect(store.hosts.map(\.label) == ["gpu"])
    store.reviewConfiguration()
    #expect(store.pendingAlignment == nil)
  }

}
