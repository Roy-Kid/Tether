import CryptoKit
import Foundation
import Testing
@testable import TetherApp
import struct TetherApp.Host

@Suite("Identity security boundaries")
struct IdentityTests {
  func profile() -> HostProfile {
    let identity = AccountIdentity(name: "University")
    return HostProfile(id: UUID(), label: "lab", hostname: "login.example.org", port: 22, username: "ada",
      authentication: AuthenticationProfile(identity: identity,
        primary: CredentialDescriptor(identityID: identity.id, purpose: .ssh)))
  }

  @Test func disjointChangesMergeAndPolicyConflictsBlock() throws {
    let original = profile()
    var local = original; local.label = "My lab"
    var remote = original; remote.tags = ["hpc"]
    var record = SharedHostRecord(profile: local, base: original)
    try record.merge(remote, deleted: false, systemFields: nil)
    #expect(record.profile.label == "My lab")
    #expect(record.profile.tags == ["hpc"])
    #expect(record.conflicts.isEmpty)
    var localPolicy = record.profile
    localPolicy.authentication.confirmation = .automatic
    record.profile = localPolicy
    remote.authentication.confirmation = .confirmConnection
    try record.merge(remote, deleted: false, systemFields: nil)
    #expect(record.conflicts.keys.contains("authentication"))
    try record.resolve(useRemote: true)
    #expect(record.profile.authentication.confirmation == .confirmConnection)
  }

  @Test func cosmeticChangesDoNotChangeApproval() {
    let original = profile()
    var edited = original; edited.label = "Renamed"; edited.tags = ["work"]
    #expect(original.securityDigest == edited.securityDigest)
    edited.hostname = "other.example.org"
    #expect(original.securityDigest != edited.securityDigest)
  }

  @Test func cosmeticEditsKeepAnOpenSession() {
    let original = profile()
    var host = Host(id: original.id, label: original.label, hostname: original.hostname, port: original.port,
      username: original.username, profile: original)
    var renamed = host
    renamed.label = "Renamed"
    renamed.profile?.label = "Renamed"
    renamed.profile?.tags = ["work"]
    #expect(renamed.sameSessionTarget(as: host))
    var moved = renamed
    moved.hostname = "other.example.org"
    moved.profile?.hostname = "other.example.org"
    #expect(!moved.sameSessionTarget(as: host))
    host.connectionProblem = "Review authentication settings"
    #expect(!host.sameSessionTarget(as: renamed))
  }

  @Test func totpRFC6238Vectors() throws {
    // Published RFC test seed; no real credential.
    let otp = try TOTP(importing: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8")
    for (time, expected) in [(59.0, "94287082"), (1111111109.0, "07081804"), (1111111111.0, "14050471"), (1234567890.0, "89005924"), (2000000000.0, "69279037"), (20000000000.0, "65353130")] {
      #expect(try otp.code(at: Date(timeIntervalSince1970: time)) == expected)
    }
  }

  @Test func malformedOTPIsRejected() {
    for text in ["abc!", "otpauth://hotp/X?secret=GEZDGNBVGY3TQOJQ", "otpauth://totp/X?secret=GEZDGNBVGY3TQOJQ&digits=9", "otpauth://totp/X?secret=GEZDGNBVGY3TQOJQ&secret=GEZDGNBVGY3TQOJQ"] {
      #expect(throws: (any Error).self) { try TOTP(importing: text) }
    }
  }

  func device(_ name: String) -> (DeviceCard, DeviceKeyMaterial) {
    let signing = Curve25519.Signing.PrivateKey()
    let agreement = Curve25519.KeyAgreement.PrivateKey()
    return (DeviceCard(id: UUID(), name: name, signingKey: signing.publicKey.rawRepresentation, agreementKey: agreement.publicKey.rawRepresentation),
      DeviceKeyMaterial(signing: signing.rawRepresentation, agreement: agreement.rawRepresentation))
  }

  @Test func envelopesRequirePairedSenderRecipientAndValidLifetime() throws {
    let (mac, macKeys) = device("Mac")
    let (phone, phoneKeys) = device("Phone")
    let (stranger, strangerKeys) = device("Stranger")
    let now = Date(timeIntervalSince1970: 1_000)
    let header = DeviceEnvelope.Header(id: UUID(), sender: mac.id, recipient: phone.id,
      expires: now.addingTimeInterval(60), kind: "test")
    let envelope = try DeviceEnvelope.seal("123456", header: header, keys: macKeys, peer: phone)
    #expect(try envelope.open(String.self, local: phone, keys: phoneKeys, peer: mac, now: now) == "123456")
    #expect(throws: (any Error).self) { try envelope.open(String.self, local: stranger, keys: strangerKeys, peer: mac, now: now) }
    #expect(throws: (any Error).self) { try envelope.open(String.self, local: phone, keys: phoneKeys, peer: stranger, now: now) }
    #expect(throws: (any Error).self) { try envelope.open(String.self, local: phone, keys: phoneKeys, peer: mac, now: now.addingTimeInterval(61)) }
    var tampered = envelope; tampered.ciphertext[0] ^= 1
    #expect(throws: (any Error).self) { try tampered.open(String.self, local: phone, keys: phoneKeys, peer: mac, now: now) }
  }

  @Test @MainActor func keyGenerationStoresOnlyLocalPrivateMaterial() throws {
    let secrets = MemorySecrets()
    let credentials = DeviceCredentialStore(secrets: secrets)
    let id = UUID()
    let publicKey = try credentials.generateSSHKey(id: id, label: "Test")
    #expect(publicKey.hasPrefix("ecdsa-sha2-nistp256 "))
    let pem = try credentials.read(id)
    #expect(pem.contains("PRIVATE KEY"))
    _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
    #expect(try AuthorizedKeysProvider.keyMaterial(publicKey).hasPrefix("ecdsa-sha2-nistp256 "))
  }

  @Test func strictExportRejectsAliasInjectionAndExistingAlias() throws {
    var p = profile(); p.authentication.confirmation = .automatic
    var host = Host(id: p.id, label: p.label, hostname: p.hostname, port: p.port, username: p.username,
      keyPath: "~/.ssh/test", profile: p)
    #expect(throws: (any Error).self) { try OpenSSHExport.render([host], existing: SSHConfig("Host lab\n HostName other\n")) }
    host.label = "lab\nProxyCommand malicious"
    #expect(throws: (any Error).self) { try OpenSSHExport.render([host], existing: SSHConfig("")) }
  }
}
