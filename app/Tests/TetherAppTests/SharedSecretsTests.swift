import Foundation
import Testing
@testable import TetherApp
import struct TetherApp.Host

/// A host's password and code seed travel with it, as its key does.
@MainActor
@Suite("Shared passwords and code seeds")
struct SharedSecretsTests {
  struct Device {
    let store: HostStore
    let secrets: MemorySecrets
    let credentials: DeviceCredentialStore
    let location: URL
  }

  static func device(_ name: String = "config") -> Device {
    let location = temporaryFile(name)
    let secrets = MemorySecrets()
    let credentials = DeviceCredentialStore(secrets: MemorySecrets())
    return Device(store: HostStore(location: location, secrets: secrets, credentials: credentials),
      secrets: secrets, credentials: credentials, location: location)
  }

  static func host() -> Host { Host(label: "lab", hostname: "login.example.org", port: 22, username: "ada") }
  static let seed = try! TOTP(secret: Data((1...20).map(UInt8.init)))

  /// What one device keeps, the next sync sends; what arrives, the other
  /// device logs in with.
  @Test func aKeptPasswordAndSeedReachTheOtherDevice() throws {
    let mac = Self.device(), phone = Self.device("phone")
    defer { removeDirectory(of: mac.location); removeDirectory(of: phone.location) }
    #expect(mac.store.save(Self.host(), password: "hunter2"))
    let host = try #require(mac.store.hosts.first)
    try mac.store.setOTP(Self.seed, for: host)
    let profile = try #require(mac.store.snapshot.records[host.id]?.profile)
    try mac.store.update { $0.records[host.id]?.dirty = false }

    mac.store.noteKeysAwaitingSync()
    #expect(mac.store.snapshot.records[host.id]?.dirty == true, "unsent secrets mark the host")
    let password = try #require(mac.store.sharedPassword(for: profile))
    let code = try #require(mac.store.sharedCode(for: profile))
    #expect(password == "hunter2")
    #expect(try TOTP(stored: code) == Self.seed)

    var sent = try #require(mac.store.snapshot.records[host.id])
    HostStore.didSendSecrets(&sent, password: password, code: code)
    try mac.store.update { $0.records[host.id] = sent; $0.records[host.id]?.dirty = false }
    mac.store.noteKeysAwaitingSync()
    #expect(mac.store.snapshot.records[host.id]?.dirty == false, "nothing new to send")

    try phone.store.receive(profile, deleted: false, systemFields: nil, password: password, code: code)
    let arrived = try #require(phone.store.hosts.first)
    #expect(arrived.passwordSecretID == HostStore.syncedPasswordID(for: host.id))
    #expect(try phone.secrets.password(for: arrived.passwordID) == "hunter2")
    #expect(arrived.otpSecretID == HostStore.syncedCodeID(for: host.id))
    #expect(try TOTP(stored: phone.credentials.read(HostStore.syncedCodeID(for: host.id))) == Self.seed)
    #expect(phone.store.snapshot.records[host.id]?.syncedPasswordDigest == HostStore.keyDigest(password))

    // The copy coming back changes nothing on the device that sent it.
    try mac.store.receive(profile, deleted: false, systemFields: nil, password: password, code: code)
    #expect(mac.store.hosts.first?.passwordSecretID == host.passwordSecretID)
  }

  /// Letting go of a password lets go of it on every device; a seed or a
  /// password that does not read as one changes nothing.
  @Test func aWithdrawnPasswordLeavesEveryDevice() throws {
    let mac = Self.device(), phone = Self.device("phone")
    defer { removeDirectory(of: mac.location); removeDirectory(of: phone.location) }
    #expect(mac.store.save(Self.host(), password: "hunter2"))
    let host = try #require(mac.store.hosts.first)
    let profile = try #require(host.profile)
    try phone.store.receive(profile, deleted: false, systemFields: nil, password: "hunter2")
    try phone.store.receive(profile, deleted: false, systemFields: nil, password: String(repeating: "x", count: 5000),
      code: "{}")
    #expect(try phone.secrets.password(for: #require(phone.store.hosts.first).passwordID) == "hunter2")

    #expect(mac.store.save(try #require(mac.store.hosts.first), password: ""))
    #expect(mac.store.snapshot.records[host.id]?.forgetSharedPassword == true)
    #expect(try mac.secrets.saved().isEmpty)

    try phone.store.receive(profile, deleted: false, systemFields: nil, password: "")
    #expect(phone.store.hosts.first?.passwordSecretID == nil)
    #expect(try phone.secrets.saved().isEmpty)
    #expect(phone.store.snapshot.records[host.id]?.syncedPasswordDigest == HostStore.clearedKey)
  }

  /// A password kept here and not sent yet is not undone by an older copy
  /// arriving, or by a withdrawal of the one before it.
  @Test func anUnsentPasswordWinsOverWhatArrives() throws {
    let mac = Self.device()
    defer { removeDirectory(of: mac.location) }
    #expect(mac.store.save(Self.host(), password: "old"))
    let host = try #require(mac.store.hosts.first)
    let profile = try #require(host.profile)
    try mac.store.receive(profile, deleted: false, systemFields: nil, password: "old")
    #expect(mac.store.save(try #require(mac.store.hosts.first), password: "new"))

    try mac.store.receive(profile, deleted: false, systemFields: nil, password: "old")
    #expect(try mac.secrets.password(for: #require(mac.store.hosts.first).passwordID) == "new")
    try mac.store.receive(profile, deleted: false, systemFields: nil, password: "")
    #expect(try mac.secrets.password(for: #require(mac.store.hosts.first).passwordID) == "new")
    #expect(mac.store.secretsAwaitSync(try #require(mac.store.snapshot.records[host.id]), in: mac.store.snapshot))
  }

  /// What a sent record carried is what counts as sent: a password kept
  /// while it was on its way still goes, and so does a withdrawal.
  @Test func whatWasSentIsWhatTheRecordCarried() throws {
    let mac = Self.device()
    defer { removeDirectory(of: mac.location) }
    #expect(mac.store.save(Self.host(), password: "carried"))
    let host = try #require(mac.store.hosts.first)
    #expect(mac.store.save(host, password: "kept-meanwhile"))
    var record = try #require(mac.store.snapshot.records[host.id])
    HostStore.didSendSecrets(&record, password: "carried", code: nil)
    #expect(mac.store.secretsAwaitSync(record, in: mac.store.snapshot))

    record.forgetSharedPassword = true
    HostStore.didSendSecrets(&record, password: "kept-meanwhile", code: nil)
    #expect(record.forgetSharedPassword == true, "the withdrawal has not gone yet")
    HostStore.didSendSecrets(&record, password: "", code: nil)
    #expect(record.forgetSharedPassword == nil)
    #expect(record.syncedPasswordDigest == HostStore.clearedKey)
  }

  /// A password removed from the list in Settings is withdrawn too.
  @Test func aPasswordForgottenInSettingsIsWithdrawn() throws {
    let mac = Self.device()
    defer { removeDirectory(of: mac.location) }
    #expect(mac.store.save(Self.host(), password: "hunter2"))
    let host = try #require(mac.store.hosts.first)
    try mac.secrets.forget(host.passwordID)
    mac.store.passwordForgotten(host.passwordID)
    #expect(mac.store.hosts.first?.passwordSecretID == nil)
    #expect(mac.store.snapshot.records[host.id]?.forgetSharedPassword == true)
  }

  /// What a person chose from an export lands on the host they chose; what
  /// they did not choose is not stored anywhere.
  @Test func adoptingAnImportKeepsOnlyWhatWasChosen() throws {
    let mac = Self.device()
    defer { removeDirectory(of: mac.location) }
    #expect(mac.store.save(Self.host()))
    let host = try #require(mac.store.hosts.first)
    let pem = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIA==\n-----END PRIVATE KEY-----\n"
    let item = CredentialExchange.Item(id: Data([1]), title: "lab", userName: "ada", names: ["lab"],
      secrets: .init(password: "hunter2", code: Self.seed, privateKey: pem))
    let skipped = CredentialExchange.Item(id: Data([2]), title: "other", userName: "ada", names: ["other"],
      secrets: .init(password: "not-this"))
    mac.store.adopt([
      .init(item: item, host: host.id, password: true, code: true, privateKey: true),
      .init(item: skipped, host: nil, password: true, code: false, privateKey: false),
    ])
    let adopted = try #require(mac.store.hosts.first)
    #expect(try mac.secrets.password(for: adopted.passwordID) == "hunter2")
    #expect(try mac.secrets.saved().count == 1)
    #expect(adopted.credentialSecretID == HostStore.syncedKeyID(for: host.id))
    #expect(try mac.credentials.read(HostStore.syncedKeyID(for: host.id)) == pem)
    let otp = try #require(adopted.otpSecretID)
    #expect(try TOTP(stored: mac.credentials.read(otp)) == Self.seed)
    #expect(adopted.profile?.authentication.otp != nil)
  }
}
