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
  /// Never the real keychain (see `MemorySecrets`).
  static func credentials() -> DeviceCredentialStore { DeviceCredentialStore(secrets: MemorySecrets()) }
  @Test func stableIdentityAndLocalBinding() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let secrets = MemorySecrets()
    let store = HostStore(location: location, secrets: secrets, credentials: Self.credentials())
    var host = Self.host()
    host.keyPath = "~/.ssh/personal"
    #expect(store.save(host, password: "saved"))
    var saved = try #require(store.hosts.first)
    #expect(saved.id == host.id)
    saved.label = "renamed"
    #expect(store.save(saved))
    let reopened = HostStore(location: location, secrets: secrets, credentials: Self.credentials())
    #expect(reopened.hosts.first?.id == host.id)
    #expect(reopened.hosts.first?.keyPath == "~/.ssh/personal")
    #expect(try secrets.password(for: #require(reopened.hosts.first).passwordID) == "saved")
    #expect(!FileManager.default.fileExists(atPath: location.path), "the library is not written into ssh's files")
    let payload = try JSONEncoder().encode(#require(store.snapshot.records[host.id]).profile)
    #expect(!String(decoding: payload, as: UTF8.self).contains(".ssh"))
    #expect(!String(decoding: payload, as: UTF8.self).contains("saved"))
  }
  /// A host that arrives from the same Apple ID is ready to connect. The
  /// private key comes with it; the path it was read from does not.
  @Test func aSyncedHostIsTrustedAndTakesThePrivateKey() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
    let keyFile = temporaryFile("id_ed25519")
    defer { removeDirectory(of: keyFile) }
    try pem.write(to: keyFile, atomically: true, encoding: .utf8)

    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: Self.credentials())
    var host = Self.host()
    host.keyPath = keyFile.path
    #expect(store.save(host))
    let profile = try #require(store.snapshot.records[host.id]?.profile)
    #expect(store.sharedPrivateKey(for: profile) == pem)

    let phoneCredentials = Self.credentials()
    let phone = HostStore(location: location.appendingPathExtension("phone"), secrets: MemorySecrets(), credentials: phoneCredentials)
    try phone.receive(profile, deleted: false, systemFields: nil, privateKey: pem)
    let arrived = try #require(phone.hosts.first)
    #expect(arrived.connectionProblem == nil)
    #expect(arrived.keyPath == nil)
    #expect(arrived.credentialSecretID == HostStore.syncedKeyID(for: profile.id))
    #expect(arrived.offersConfiguredKey)
    #expect(try phoneCredentials.read(HostStore.syncedKeyID(for: profile.id)) == pem)
    #expect(phone.snapshot.approvals[profile.id] == profile.securityDigest)

    // The Mac keeps reading the file. A copy of the key coming back does not
    // replace that file with the keychain item.
    try store.receive(profile, deleted: false, systemFields: nil, privateKey: pem)
    #expect(store.hosts.first?.keyPath == keyFile.path)
    #expect(store.hosts.first?.credentialSecretID == nil)

    try phone.receive(profile, deleted: false, systemFields: nil, privateKey: "not-a-key")
    #expect(phone.hosts.first?.credentialSecretID == HostStore.syncedKeyID(for: profile.id))
    try phone.receive(profile, deleted: false, systemFields: nil, privateKey: "")
    #expect(phone.hosts.first?.credentialSecretID == nil)
    #expect(try phoneCredentials.saved().isEmpty)
  }

  /// A library saved before review went away opens already trusted.
  @Test func aReopenedLibraryDoesNotWaitForReview() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let secrets = MemorySecrets()
    let credentials = Self.credentials()
    let store = HostStore(location: location, secrets: secrets, credentials: credentials)
    #expect(store.save(Self.host()))
    let id = try #require(store.hosts.first?.id)
    try store.update { $0.approvals = [:] }
    let reopened = HostStore(location: location, secrets: secrets, credentials: credentials)
    #expect(reopened.hosts.first?.connectionProblem == nil)
    #expect(reopened.snapshot.approvals[id] == reopened.snapshot.records[id]?.profile.securityDigest)
  }

  /// Choosing or creating a key does not change the host the other devices
  /// already have. It does send the key.
  @Test func aDeviceChoosingItsKeySharesThatKey() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let credentials = Self.credentials()
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: credentials)
    #expect(store.save(Self.host(), password: "typed"))
    try store.update { $0.records[$0.records.keys.first!]?.dirty = false }
    let before = try #require(store.hosts.first?.profile)

    var keyed = try #require(store.hosts.first)
    let secret = UUID()
    let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nBBBB\n-----END OPENSSH PRIVATE KEY-----\n"
    try credentials.write(pem, id: secret, label: "lab")
    keyed.credentialSecretID = secret
    #expect(store.save(keyed, password: ""))
    #expect(store.hosts.first?.profile == before)
    #expect(store.snapshot.records[before.id]?.dirty == true)
    #expect(store.sharedPrivateKey(for: before) == pem)
    #expect(store.hosts.first?.offersConfiguredKey == true)

    store.generateKey(for: try #require(store.hosts.first))
    #expect(store.hosts.first?.profile == before)
    #expect(store.snapshot.records[before.id]?.dirty == true)
    #expect(store.hosts.first?.credentialSecretID == HostStore.syncedKeyID(for: before.id))
    #expect(try credentials.saved().count == 1, "the generated key replaced the picked one")
    let generated = try credentials.read(HostStore.syncedKeyID(for: before.id))
    #expect(HostStore.looksLikePrivateKey(generated))
    #expect(store.sharedPrivateKey(for: before) == generated)
  }

  /// A deleted host takes its key and password with it, whether it was
  /// deleted here or on another device.
  @Test func deletingAHostReleasesItsSecrets() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let secrets = MemorySecrets()
    let credentials = Self.credentials()
    let store = HostStore(location: location, secrets: secrets, credentials: credentials)
    for label in ["here", "there"] {
      var host = Self.host(label)
      let key = UUID()
      try credentials.write("PEM", id: key, label: label)
      host.credentialSecretID = key
      #expect(store.save(host, password: "pw"))
    }
    #expect(try credentials.saved().count == 2)
    #expect(try secrets.saved().count == 2)

    store.delete(try #require(store.hosts.first { $0.label == "here" }))
    let there = try #require(store.hosts.first { $0.label == "there" }?.profile)
    try store.receive(there, deleted: true, systemFields: nil)

    #expect(store.hosts.isEmpty)
    #expect(try credentials.saved().isEmpty)
    #expect(try secrets.saved().isEmpty)
    #expect(store.snapshot.bindings.isEmpty)
  }




  @Test func tombstoneSurvivesOfflineEdit() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: Self.credentials())
    let host = Self.host(); #expect(store.save(host))
    let managed = try #require(store.hosts.first)
    let profile = try #require(managed.profile)
    store.delete(managed)
    try store.receive(profile, deleted: false, systemFields: nil)
    #expect(store.hosts.isEmpty)
    #expect(store.snapshot.records[host.id]?.deleted == true)
    #expect(!store.save(managed))
  }
  /// Hosts kept before signing in join the first account to sign in, and
  /// only that one: they move rather than copy.
  @Test func accountLibrariesStaySeparate() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: Self.credentials())
    #expect(store.save(Self.host()))
    try store.switchAccount("icloud:A")
    #expect(store.hosts.isEmpty)
    store.importLocalLibrary()
    #expect(store.hosts.count == 1)
    try store.switchAccount("icloud:B")
    store.importLocalLibrary()
    #expect(store.hosts.isEmpty, "already moved to A")
    try store.switchAccount("local")
    #expect(store.hosts.isEmpty)
    try store.switchAccount("icloud:A")
    #expect(store.hosts.count == 1)
  }
  @Test func failedKeychainWriteDoesNotSave() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let secrets = MemorySecrets(); secrets.refusing = true
    let store = HostStore(location: location, secrets: secrets, credentials: Self.credentials())
    #expect(!store.save(Self.host(), password: "secret"))
    #expect(store.hosts.isEmpty)
    #expect(store.problem != nil)
  }

  // MARK: - What the review found

  /// A library iCloud removed — purged, reset, records gone without a
  /// tombstone — takes the hosts, not the keys this device made for them.
  @Test func aLibraryICloudRemovedKeepsThisDevicesKeys() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let credentials = Self.credentials()
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: credentials)
    var host = Self.host()
    let key = UUID()
    try credentials.write("PEM", id: key, label: "lab")
    host.credentialSecretID = key
    #expect(store.save(host))

    try store.vanish()
    #expect(store.hosts.isEmpty)
    #expect(try credentials.saved().map(\.id) == [key])

    try store.prepareReupload()
    #expect(store.snapshot.records[host.id]?.dirty == true)
    #expect(store.snapshot.records[host.id]?.systemFields == nil)
  }



  /// A sheet opened before a key was made cannot save that key away.
  @Test func aStaleSheetCannotUndoANewKey() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let credentials = Self.credentials()
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: credentials)
    #expect(store.save(Self.host()))
    let sheet = try #require(store.hosts.first)
    store.generateKey(for: sheet)
    #expect(try credentials.saved().count == 1)

    #expect(!store.save(sheet))
    #expect(try credentials.saved().count == 1, "the generated key is still there")
    #expect(store.hosts.first?.offersConfiguredKey == true)
  }

  /// A secret another account's library still points at is not let go of
  /// when this one stops needing it.
  @Test func anotherLibrarysSecretIsKept() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let credentials = Self.credentials()
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: credentials)
    var host = Self.host()
    let key = UUID()
    try credentials.write("PEM", id: key, label: "lab")
    host.credentialSecretID = key
    #expect(store.save(host))
    let copied = store.snapshot
    try store.switchAccount("icloud:A")
    try store.update { state in
      state.records = copied.records
      state.bindings = copied.bindings
      state.approvals = copied.approvals
    }
    store.delete(try #require(store.hosts.first))
    #expect(try credentials.saved().map(\.id) == [key], "the local library still uses it")
  }

  /// Two devices setting up the same host's code name it the same way, and a
  /// seed bound under an older name follows the setting instead of being lost.
  @Test func aCodeSeedFollowsItsHost() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let credentials = Self.credentials()
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: credentials)
    #expect(store.save(Self.host()))
    let profile = try #require(store.hosts.first?.profile)
    #expect(CredentialDescriptor.oneTimeCode(for: profile).id == CredentialDescriptor.oneTimeCode(for: profile).id)

    store.setOTP("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", for: try #require(store.hosts.first))
    let seeded = try #require(store.hosts.first?.profile)
    #expect(store.hosts.first?.otpSecretID != nil)
    var renamed = seeded
    renamed.authentication.otp?.id = UUID()
    try store.update { $0.records[seeded.id]?.base = seeded; $0.records[seeded.id]?.dirty = false }
    try store.receive(renamed, deleted: false, systemFields: nil)
    #expect(store.hosts.first?.otpSecretID != nil, "the seed followed the new name")
    #expect(try credentials.saved().count == 1)
  }

  /// A seed is a credential like a key or a password, not a policy: keeping
  /// one does not start asking for approval before every login.
  @Test func aCodeSeedLeavesConfirmationAlone() throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: Self.credentials())
    #expect(store.save(Self.host()))
    #expect(store.hosts.first?.profile?.authentication.confirmation == .automatic)

    store.setOTP("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", for: try #require(store.hosts.first))
    #expect(store.hosts.first?.otpSecretID != nil)
    #expect(store.hosts.first?.profile?.authentication.confirmation == .automatic)
  }

  /// A library a version before that fix wrote: a host with a seed, asking
  /// before every login, last edited before the fix existed.
  static func libraryWithForcedConfirmation(modified: Date) throws -> (URL, HostStore) {
    let location = temporaryFile("config")
    let store = HostStore(location: location, secrets: MemorySecrets(), credentials: Self.credentials())
    #expect(store.save(Self.host()))
    store.setOTP("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", for: try #require(store.hosts.first))
    let id = try #require(store.hosts.first?.id)
    try store.update { state in
      state.records[id]?.profile.authentication.confirmation = .confirmAuthentication
      state.records[id]?.profile.modified = modified
      state.records[id]?.dirty = false
    }
    return (location, store)
  }

  /// What that version set behind someone's back is undone once, on the
  /// next launch, and the change travels to their other devices.
  @Test func aConfirmationTheSeedForcedIsUndone() throws {
    let (location, _) = try Self.libraryWithForcedConfirmation(
      modified: HostStore.seedStoppedForcingConfirmation.addingTimeInterval(-86_400))
    defer { removeDirectory(of: location) }

    let reopened = HostStore(location: location, secrets: MemorySecrets(), credentials: Self.credentials())
    let host = try #require(reopened.hosts.first)
    #expect(host.profile?.authentication.confirmation == .automatic)
    #expect(reopened.snapshot.records[host.id]?.dirty == true)
    #expect((host.profile?.modified ?? .distantPast) > HostStore.seedStoppedForcingConfirmation)
    #expect(reopened.snapshot.approvals[host.id] == host.profile?.securityDigest)
  }

  /// One chosen since is a choice, and stays.
  @Test func aConfirmationChosenSinceTheFixStays() throws {
    let (location, _) = try Self.libraryWithForcedConfirmation(modified: Date())
    defer { removeDirectory(of: location) }

    let reopened = HostStore(location: location, secrets: MemorySecrets(), credentials: Self.credentials())
    #expect(reopened.hosts.first?.profile?.authentication.confirmation == .confirmAuthentication)
  }

  /// The SSH file and the keychain are read by `refresh`, off the main
  /// actor, not by opening the store. A password kept or let go of here is
  /// known at once, without listing the keychain again.
  @Test func refreshReadsWhatOpeningDoesNot() async throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    try "Host lab\n  HostName login.example.org\n".write(to: location, atomically: true, encoding: .utf8)
    let secrets = MemorySecrets()
    let first = HostStore(location: location, secrets: secrets, credentials: Self.credentials())
    #expect(first.save(Self.host(), password: "saved"))
    #expect(first.hosts.first?.remembersPassword == true)

    let store = HostStore(location: location, secrets: secrets, credentials: Self.credentials())
    #expect(store.config.entries.isEmpty, "opening reads neither the file nor the keychain")
    #expect(store.hosts.first?.remembersPassword == true, "the library's word, until the keychain is listed")
    try secrets.forget(#require(store.hosts.first).passwordID)
    await store.refresh()
    #expect(store.config.entries.map(\.alias) == ["lab"])
    #expect(store.hosts.first?.remembersPassword == false, "the listing found no password")

    #expect(try store.save(#require(store.hosts.first), password: "again"))
    #expect(store.hosts.first?.remembersPassword == true)
    let id = try #require(store.hosts.first).passwordID
    try secrets.forget(id)
    store.passwordForgotten(id)
    #expect(store.hosts.first?.remembersPassword == false)
  }

  /// A password kept while the keychain is still being listed is not lost
  /// when the older listing lands.
  @Test func aListingInFlightDoesNotUndoAChange() async throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let secrets = GatedSecrets()
    let store = HostStore(location: location, secrets: secrets, credentials: Self.credentials())
    #expect(store.save(Self.host()))
    async let refreshed: Void = store.refresh()
    try await Task.sleep(for: .milliseconds(50))
    #expect(try store.save(#require(store.hosts.first), password: "kept"))
    secrets.open()
    await refreshed
    #expect(store.hosts.first?.remembersPassword == true)
  }
}

/// A keychain whose listing waits until the test lets it answer — with what
/// it held when it was asked.
final class GatedSecrets: SecretStore, @unchecked Sendable {
  private let gate = DispatchSemaphore(value: 0)
  private let inner = MemorySecrets()
  func open() { gate.signal() }
  func password(for host: UUID) throws -> String? { try inner.password(for: host) }
  func remember(_ password: String, for host: Host) throws { try inner.remember(password, for: host) }
  func forget(_ host: UUID) throws { try inner.forget(host) }
  func saved() throws -> [SavedSecret] {
    let listed = try inner.saved()
    gate.wait()
    gate.signal()
    return listed
  }
}
