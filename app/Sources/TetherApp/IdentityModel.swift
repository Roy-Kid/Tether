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
  /// When a person last changed it, wherever they did: in Tether, or in a
  /// Mac's SSH configuration — then it is the file's modification time. What
  /// decides between two edits that crossed.
  var modified: Date?
  /// Settings of the SSH configuration it came from that Tether cannot
  /// follow yet — a jump host, a proxy command. Such a host is still one of
  /// the hosts; it just cannot be reached from here except by `ssh` itself.
  var unsupported: [String]?

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
    copy.modified = nil
    return SHA256.hash(data: (try? encoder.encode(copy)) ?? Data()).map { String(format: "%02x", $0) }.joined()
  }
}

struct LocalCredentialBinding: Codable, Hashable, Sendable {
  var credentialID: UUID
  var keyPath: String?
  var secretID: UUID?
  var publicKey: String?
  /// This device logs in the way `ssh` does here with no `IdentityFile`:
  /// with whichever default key files exist. What an ssh-config entry that
  /// names no key becomes when it is added to Tether.
  var defaultKeys: Bool?
}

/// A UUID that is a function of `name`: the same name, on any device, is
/// the same identifier. Marked as name-based (version 5) rather than random.
func nameBasedUUID(_ name: String) -> UUID {
  var digest = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
  digest[6] = (digest[6] & 0x0F) | 0x50
  digest[8] = (digest[8] & 0x3F) | 0x80
  return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
    digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
}

extension CredentialDescriptor {
  /// The one-time-code credential a host has, named after the host rather
  /// than invented: two devices setting up the same host's code before they
  /// have synchronized then agree on it, instead of each binding its seed to
  /// an identifier the other side's settings will replace.
  static func oneTimeCode(for profile: HostProfile) -> CredentialDescriptor {
    CredentialDescriptor(id: nameBasedUUID("totp:" + profile.id.uuidString),
      identityID: profile.authentication.identity.id, purpose: .totp)
  }
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
  /// Gone because iCloud removed it — a purged or reset library, a record
  /// deleted without a tombstone — rather than because a person deleted it.
  /// The keys this device made for it are kept: they never left the device,
  /// and nobody chose to throw them away.
  var vanished: Bool?
  var dirty = true
  var conflicts: [String: FieldConflict] = [:]
  var systemFields: Data?
  /// SHA-256 of the private key last sent or received for this host, or
  /// `cleared` once someone removed it. The digest only — never the key.
  var syncedKeyDigest: String?
  /// The next sync withdraws the shared private key.
  var forgetSharedKey: Bool?

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
    // When it changed is not something two edits disagree about; the later
    // of the two is simply when it last changed.
    let latest = [profile.modified, remote.modified].compactMap { $0 }.max()
    let remoteIsNewer = (remote.modified ?? .distantPast) > (profile.modified ?? .distantPast)
    var local = try Self.fields(profile)
    var other = try Self.fields(remote)
    var ancestor = try base.map(Self.fields) ?? [:]
    for key in ["modified"] {
      local.removeValue(forKey: key); other.removeValue(forKey: key); ancestor.removeValue(forKey: key)
    }
    var merged = local
    for key in Set(local.keys).union(other.keys) {
      if local[key] == other[key] {
        conflicts.removeValue(forKey: key)
      } else if local[key] == ancestor[key] {
        merged[key] = other[key]
        conflicts.removeValue(forKey: key)
      } else if other[key] != ancestor[key] {
        // Where a host is and what it is called, two edits settle by which
        // came last. How it authenticates never does: half of one policy and
        // half of another could let in a login nobody chose.
        if Self.settledByTime.contains(key) {
          if remoteIsNewer { merged[key] = other[key] }
          conflicts.removeValue(forKey: key)
        } else {
          conflicts[key] = FieldConflict(local: local[key], remote: other[key])
        }
      }
    }
    profile = try Self.profile(merged)
    profile.modified = latest
    base = remote
    dirty = profile != remote
  }

  private static let settledByTime: Set<String> = ["label", "hostname", "username", "port", "tags", "unsupported"]

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
  /// The server's key is not the one pinned for it. Not a question to answer
  /// mid-login: someone rotating a key and someone in the middle look alike.
  case hostKeyChanged
  /// The same, where the key on record is system ssh's, in `known_hosts`.
  case systemHostKeyChanged
  /// A question the login asked went unanswered for too long.
  case unanswered
  /// A question the login asked could not be put on screen.
  case unshown
  var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "Invalid authentication configuration."
    case .missingCredential: "Set up this device’s identity before connecting."
    case .needsReview: "Review this host’s authentication settings before connecting."
    case .unsupportedRoute: "This route requires an SSH transport that is not available on this device."
    case .storage(let message): message
    case .expired: "The authentication request expired."
    case .untrustedDevice: "This device is not authorized for this operation."
    case .hostKeyChanged: "This host’s key has changed. Forget the old key in Settings to trust the new one."
    case .systemHostKeyChanged: "This host’s key differs from the one ssh recorded in known_hosts."
    case .unanswered: "No answer in time."
    case .unshown: "The login asked a question that could not be shown."
    }
  }
}
