import CryptoKit
import Foundation

/// Durable application objects. Secret bytes and filesystem paths never belong here.
struct AccountIdentity: Codable, Hashable, Identifiable, Sendable {
  var id = UUID()
  var name: String
}

enum CredentialPurpose: String, Codable, Sendable { case ssh, password, totp, deviceSigning }
enum CredentialPortability: String, Codable, Sendable { case deviceBound, synchronized }
struct CredentialDescriptor: Codable, Hashable, Identifiable, Sendable {
  var id = UUID()
  var identityID: UUID?
  var deviceID: UUID?
  var purpose: CredentialPurpose
  var portability: CredentialPortability = .deviceBound
  var exportable = false
}

enum ConfirmationPolicy: String, Codable, CaseIterable, Sendable {
  case automatic, confirmAuthentication, confirmConnection
}
struct AuthenticationProfile: Codable, Hashable, Identifiable, Sendable {
  var id = UUID()
  var identity: AccountIdentity
  var primary: CredentialDescriptor
  var otp: CredentialDescriptor?
  var confirmation: ConfirmationPolicy = .confirmAuthentication
  /// Exact configured challenge label; it routes an already authorized OTP, never selects a secret.
  var otpPrompt = "Verification code:"
  var remoteApprovalDevice: UUID?
}

struct HostProfile: Codable, Hashable, Identifiable, Sendable {
  var id: UUID
  var label: String
  var hostname: String
  var port: UInt16
  var username: String
  var tags: [String] = []
  var jumpHosts: [UUID] = []
  var authentication: AuthenticationProfile

  func validate() throws {
    guard !hostname.isEmpty, !username.isEmpty, port > 0,
      !hostname.hasPrefix("-"), !username.hasPrefix("-"),
      !hostname.contains(where: { $0.isWhitespace || $0.isNewline }),
      !username.contains(where: { $0.isWhitespace || $0.isNewline }),
      !label.contains(where: \.isNewline),
      !jumpHosts.contains(id), Set(jumpHosts).count == jumpHosts.count,
      authentication.primary.identityID == authentication.identity.id,
      authentication.primary.purpose == .ssh || authentication.primary.purpose == .password,
      authentication.otp == nil || authentication.otp?.purpose == .totp
    else { throw IdentityError.invalidConfiguration }
  }

  var versionDigest: String {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
  }

  /// Approval includes endpoint, user, route and the entire authentication policy.
  /// Cosmetic edits need no new approval.
  var securityDigest: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var copy = self
    copy.label = ""
    copy.tags = []
    return SHA256.hash(data: (try? encoder.encode(copy)) ?? Data()).map { String(format: "%02x", $0) }.joined()
  }
}

struct LocalCredentialBinding: Codable, Hashable, Sendable {
  var credentialID: UUID
  var keyPath: String?
  var secretID: UUID?
  var publicKey: String?
}

struct FieldConflict: Codable, Hashable, Sendable {
  var local: Data?
  var remote: Data?
}

/// Each top-level field has a three-way merge. Authentication is deliberately one
/// atomic field: merging half of two policies could authorize an unintended login.
struct SharedHostRecord: Codable, Sendable {
  var profile: HostProfile
  var base: HostProfile?
  var deleted = false
  var dirty = true
  var conflicts: [String: FieldConflict] = [:]
  var systemFields: Data?

  mutating func merge(_ remote: HostProfile, deleted remoteDeleted: Bool, systemFields: Data?) throws {
    guard remote.id == profile.id else { throw IdentityError.invalidConfiguration }
    try remote.validate()
    self.systemFields = systemFields
    if deleted || remoteDeleted {
      deleted = true // Tombstones cannot be resurrected by an offline edit.
      dirty = !remoteDeleted
      base = remote
      conflicts = [:]
      return
    }
    let local = try Self.fields(profile)
    let other = try Self.fields(remote)
    let ancestor = try base.map(Self.fields) ?? [:]
    var merged = local
    for key in Set(local.keys).union(other.keys) {
      if local[key] == other[key] {
        conflicts.removeValue(forKey: key)
      } else if local[key] == ancestor[key] {
        merged[key] = other[key]
        conflicts.removeValue(forKey: key)
      } else if other[key] != ancestor[key] {
        conflicts[key] = FieldConflict(local: local[key], remote: other[key])
      }
    }
    profile = try Self.profile(merged)
    base = remote
    dirty = profile != remote
  }

  mutating func resolve(useRemote: Bool) throws {
    var fields = try Self.fields(profile)
    for (key, conflict) in conflicts { fields[key] = useRemote ? conflict.remote : conflict.local }
    profile = try Self.profile(fields)
    try profile.validate()
    conflicts = [:]
    dirty = true
  }

  private static func fields(_ profile: HostProfile) throws -> [String: Data] {
    let data = try JSONEncoder().encode(profile)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return try object.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
  }
  private static func profile(_ fields: [String: Data]) throws -> HostProfile {
    let object = try fields.mapValues { try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
    return try JSONDecoder().decode(HostProfile.self, from: JSONSerialization.data(withJSONObject: object))
  }
}

enum IdentityError: LocalizedError {
  case invalidConfiguration, missingCredential, needsReview, unsupportedRoute, storage(String), expired, untrustedDevice
  var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "Invalid authentication configuration."
    case .missingCredential: "Set up this device’s identity before connecting."
    case .needsReview: "Review this host’s authentication settings before connecting."
    case .unsupportedRoute: "This route requires an SSH transport that is not available on this device."
    case .storage(let message): message
    case .expired: "The authentication request expired."
    case .untrustedDevice: "This device is not authorized for this operation."
    }
  }
}
