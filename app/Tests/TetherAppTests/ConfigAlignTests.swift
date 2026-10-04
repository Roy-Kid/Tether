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

  @Test("nothing to ask when the file already says what the library says")
  func alreadyAligned() {
    let record = Self.record()
    let plan = Self.plan([Self.entry()], [record], links: ["lab": ImportLink(id: record.profile.id, file: Self.config, seen: nil)])
    #expect(plan.isEmpty)
  }

  @Test("a library change to a stanza of this file is an edit of that stanza")
  func libraryAhead() {
    let record = Self.record(host: "10.0.0.9")
    let plan = Self.plan([Self.entry()], [record])
    #expect(plan.edits == [ConfigAlign.Edit.update(Self.face(), from: nil)])
    #expect(plan.title == "Update SSH configuration?")
    #expect(plan.message == "lab")
  }

  @Test("a host only the library has is added, and a deleted one is removed")
  func addAndRemove() {
    let added = Self.record(label: "gpu", host: "10.0.0.8")
    let gone = Self.record(deleted: true)
    let plan = Self.plan([Self.entry()], [added, gone],
      links: ["lab": ImportLink(id: gone.profile.id, file: Self.config, seen: nil)],
      keys: [added.profile.id: "~/.ssh/id_gpu"])
    #expect(plan.edits == [
      ConfigAlign.Edit.append(Self.face("gpu", host: "10.0.0.8"), keyPath: "~/.ssh/id_gpu"),
      ConfigAlign.Edit.remove("lab"),
    ])
  }

  @Test("a renamed host keeps its stanza")
  func renamed() {
    let record = Self.record(label: "gpu")
    let plan = Self.plan([Self.entry()], [record],
      links: ["lab": ImportLink(id: record.profile.id, file: Self.config, seen: nil)])
    #expect(plan.edits == [ConfigAlign.Edit.update(Self.face("gpu", host: "10.0.0.4"), from: "lab")])
  }

  @Test("a stanza in an included file is covered, not edited there")
  func includedFileIsOnlyRead() {
    let record = Self.record(host: "10.0.0.9")
    let plan = Self.plan([Self.entry(file: "/Users/ada/.ssh/config.d/lab")], [record])
    #expect(plan.edits == [ConfigAlign.Edit.cover(Self.face(), keyPath: nil)])
  }

  @Test("the question names a few hosts, then a count")
  func messageCounts() {
    let records = (1...5).map { Self.record(label: "h\($0)", host: "10.0.0.\($0)") }
    let plan = Self.plan([], records)
    #expect(plan.message == "h1, h2, h3, h4, +1")
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

  @Test("a new host is inserted before Host *, with its key")
  func appendsBeforeTheWildcard() {
    let original = "Host *\n  User ada\n"
    let written = SSHConfigRewrite.applying(
      [.append(Self.face("gpu", host: "10.0.0.8"), keyPath: "~/.ssh/id gpu")], to: original, defaultUser: "ada")
    #expect(written.hasPrefix("Host gpu\n  HostName 10.0.0.8\n  User ada\n  IdentityFile \"~/.ssh/id gpu\"\n\nHost *\n"))
  }

  @Test("a Host * above the stanza does not keep the old user")
  func wildcardLosesToTheBlock() {
    let original = """
      Host *
        User ada

      Host lab
        HostName 10.0.0.4
        User ada
      """
    let written = SSHConfigRewrite.applying(
      [.update(Self.face(user: "bob"), from: nil)], to: original, defaultUser: "ada")
    #expect(written.hasPrefix("# Begin Tether hosts\nHost lab\n  HostName 10.0.0.9\n  User bob\n# End Tether hosts\n"))
    #expect(written.contains("User ada"))
    let face = HostFace(SSHConfig(written).entries[0], defaultUser: "ada")
    #expect(face == Self.face(user: "bob"))
  }

  @Test("agreeing a second time replaces the block instead of stacking it")
  func blockIsReplaced() {
    let once = SSHConfigRewrite.applying(
      [.update(Self.face(user: "bob"), from: nil)],
      to: "Host *\n  User ada\n\nHost lab\n  HostName 10.0.0.4\n  User ada\n", defaultUser: "ada")
    let twice = SSHConfigRewrite.applying(
      [.update(Self.face(host: "10.0.0.7", user: "bob"), from: nil)], to: once, defaultUser: "ada")
    #expect(twice.components(separatedBy: "# Begin Tether hosts").count == 2)
    #expect(HostFace(SSHConfig(twice).entries[0], defaultUser: "ada").hostName == "10.0.0.7")
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

  @Test("a symlink stays a symlink")
  func symlink() throws {
    let directory = temporaryFile("config").deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "real")
    let link = directory.appending(path: "config")
    try "Host lab\n  HostName 10.0.0.4\n  User ada\n".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let store = HostStore(location: link, secrets: MemorySecrets(), credentials: DeviceCredentialStore(secrets: MemorySecrets()))
    store.reconcile()
    var lab = try #require(store.hosts.first)
    lab.hostname = "10.0.0.9"
    #expect(store.save(lab))
    store.reconcile()
    store.reviewConfiguration()
    store.writeConfigurationAlignment()
    #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try String(contentsOf: target, encoding: .utf8).contains("10.0.0.9"))
  }
}
