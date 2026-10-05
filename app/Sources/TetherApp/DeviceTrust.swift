import CryptoKit
import Foundation

struct DeviceCard: Codable, Hashable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var signingKey: Data
  var agreementKey: Data
  var fingerprint: String {
    SHA256.hash(data: signingKey + agreementKey).map { String(format: "%02x", $0) }.joined(separator: ":")
  }
  var pairingCode: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }
  static func parse(_ text: String) throws -> DeviceCard {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count < 4096 else {
      throw IdentityError.invalidConfiguration
    }
    let card = try JSONDecoder().decode(Self.self, from: data)
    _ = try Curve25519.Signing.PublicKey(rawRepresentation: card.signingKey)
    _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: card.agreementKey)
    guard !card.name.isEmpty, card.name.count <= 128 else { throw IdentityError.invalidConfiguration }
    return card
  }
}

struct DeviceKeyMaterial: Codable {
  var signing: Data
  var agreement: Data
}
struct TrustedPeer: Codable, Identifiable {
  var card: DeviceCard
  var revoked = false
  var id: UUID { card.id }
}
struct DeviceTrustState: Codable {
  var local: DeviceCard?
  var secretID: UUID?
  var peers: [UUID: TrustedPeer] = [:]
  var consumed: [UUID: Date] = [:]
  var localRevoked = false
  var revocations: [UUID: SignedDeviceRevocation] = [:]
}

struct ApprovalRequest: Codable, Hashable, Identifiable, Sendable {
  var id = UUID()
  var sender: UUID
  var recipient: UUID
  var hostID: UUID
  var hostname: String
  var port: UInt16
  var username: String
  var hostFingerprint: String
  var profileDigest: String
  var credentialID: UUID
  var created: Date
  var expires: Date
}
struct ApprovalResponse: Codable, Sendable {
  var request: ApprovalRequest
  var code: String?
  var validUntil: Date
}

/// Public routing metadata is authenticated as AES-GCM AAD and by a signature.
/// Only the paired recipient can decrypt the body.
struct DeviceEnvelope: Codable, Sendable {
  struct Header: Codable, Sendable {
    var version = 1
    var id: UUID
    var sender: UUID
    var recipient: UUID
    var expires: Date
    var kind: String
  }
  var header: Header
  var ciphertext: Data
  var signature: Data

  private static func encoding<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
  }
  static func seal<T: Encodable>(_ value: T, header: Header, keys: DeviceKeyMaterial, peer: DeviceCard) throws -> Self {
    guard header.recipient == peer.id else { throw IdentityError.untrustedDevice }
    let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keys.agreement)
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.agreementKey))
    let aad = try encoding(header)
    let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("Tether continuity v1".utf8), sharedInfo: aad, outputByteCount: 32)
    let ciphertext = try AES.GCM.seal(encoding(value), using: key, authenticating: aad).combined!
    let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: keys.signing).signature(for: aad + ciphertext)
    return Self(header: header, ciphertext: ciphertext, signature: signature)
  }
  func open<T: Decodable>(_ type: T.Type, local: DeviceCard, keys: DeviceKeyMaterial, peer: DeviceCard, now: Date = Date()) throws -> T {
    guard header.version == 1, header.sender == peer.id, header.recipient == local.id,
      header.expires > now, header.expires.timeIntervalSince(now) <= 120,
      ciphertext.count <= 16_384 else { throw IdentityError.expired }
    let aad = try Self.encoding(header)
    guard try Curve25519.Signing.PublicKey(rawRepresentation: peer.signingKey).isValidSignature(signature, for: aad + ciphertext) else {
      throw IdentityError.untrustedDevice
    }
    let shared = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keys.agreement)
      .sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.agreementKey))
    let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("Tether continuity v1".utf8), sharedInfo: aad, outputByteCount: 32)
    let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: aad)
    return try JSONDecoder().decode(type, from: plaintext)
  }
}

struct DeviceRevocation: Codable, Sendable {
  var id = UUID()
  var issuer: UUID
  var recipient: UUID
  var revokedDevice: UUID
  var issuedAt = Date()
}
struct SignedDeviceRevocation: Codable, Sendable {
  var payload: Data
  var signature: Data
  func verify(using card: DeviceCard) throws -> DeviceRevocation {
    guard try Curve25519.Signing.PublicKey(rawRepresentation: card.signingKey).isValidSignature(signature, for: payload) else {
      throw IdentityError.untrustedDevice
    }
    let notice = try JSONDecoder().decode(DeviceRevocation.self, from: payload)
    guard notice.issuer == card.id else { throw IdentityError.untrustedDevice }
    return notice
  }
}
