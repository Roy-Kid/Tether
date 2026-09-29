import CryptoKit
import Foundation

/// Device-local credentials use distinct Keychain items, even when two hosts
/// reference the same logical account. No secret is included in HostProfile.
struct DeviceCredentialStore: Sendable {
  let secrets: any SecretStore
  init(secrets: any SecretStore = Keychain(service: "dev.tether.device-credentials")) { self.secrets = secrets }

  func read(_ id: UUID) throws -> String {
    guard let value = try secrets.password(for: id) else { throw IdentityError.missingCredential }
    return value
  }
  func write(_ value: String, id: UUID, label: String) throws {
    try secrets.remember(value, for: Host(id: id, label: label, hostname: label, port: 22, username: "credential"))
  }
  func forget(_ id: UUID) throws { try secrets.forget(id) }
  func saved() throws -> [SavedSecret] { try secrets.saved() }
  func generateSSHKey(id: UUID, label: String) throws -> String {
    let key = P256.Signing.PrivateKey()
    try write(key.pemRepresentation, id: id, label: label)
    var publicBlob = Data()
    for field in [Data("ecdsa-sha2-nistp256".utf8), Data("nistp256".utf8), key.publicKey.x963Representation] {
      var length = UInt32(field.count).bigEndian
      withUnsafeBytes(of: &length) { publicBlob.append(contentsOf: $0) }
      publicBlob.append(field)
    }
    return "ecdsa-sha2-nistp256 \(publicBlob.base64EncodedString()) tether-\(id.uuidString)"
  }
}

/// RFC 6238. CryptoKit supplies HMAC; only URI/base32 parsing and truncation
/// live here. The encoded seed is kept solely in Credential Store.
struct TOTP: Codable, Sendable {
  enum Algorithm: String, Codable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }
  var secret: Data
  var algorithm: Algorithm = .sha1
  var digits = 6
  var period = 30

  init(importing text: String) throws {
    var seed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if seed.lowercased().hasPrefix("otpauth:") {
      guard let uri = URLComponents(string: seed), uri.scheme?.lowercased() == "otpauth", uri.host == "totp" else { throw IdentityError.invalidConfiguration }
      let pairs = uri.queryItems ?? []
      guard Set(pairs.map(\.name)).count == pairs.count else { throw IdentityError.invalidConfiguration }
      let values = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
      guard let value = values["secret"] else { throw IdentityError.invalidConfiguration }
      seed = value
      if let value = values["algorithm"] {
        guard let parsed = Algorithm(rawValue: value.uppercased()) else { throw IdentityError.invalidConfiguration }
        algorithm = parsed
      }
      if let value = values["digits"] { guard let parsed = Int(value) else { throw IdentityError.invalidConfiguration }; digits = parsed }
      if let value = values["period"] { guard let parsed = Int(value) else { throw IdentityError.invalidConfiguration }; period = parsed }
    }
    guard [6, 8].contains(digits), (15...120).contains(period) else { throw IdentityError.invalidConfiguration }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var buffer: UInt32 = 0
    var bits = 0
    var bytes = Data()
    var padded = false
    for character in seed.uppercased().filter({ !$0.isWhitespace }) {
      if character == "=" { padded = true; continue }
      guard !padded, let value = alphabet.firstIndex(of: character) else { throw IdentityError.invalidConfiguration }
      buffer = (buffer << 5) | UInt32(value); bits += 5
      if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 255)) }
    }
    guard bytes.count >= 10, bits < 5, (buffer & ((1 << bits) - 1)) == 0 else { throw IdentityError.invalidConfiguration }
    secret = bytes
  }

  func code(at date: Date = Date()) throws -> String {
    guard date.timeIntervalSince1970 >= 0, [6, 8].contains(digits), period > 0 else { throw IdentityError.invalidConfiguration }
    var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
    let message = withUnsafeBytes(of: &counter) { Data($0) }
    let key = SymmetricKey(data: secret)
    let digest: [UInt8]
    switch algorithm {
    case .sha1: digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
    case .sha256: digest = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
    case .sha512: digest = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
    }
    let offset = Int(digest.last! & 15)
    let truncated = digest[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fffffff
    let divisor: UInt32 = digits == 8 ? 100_000_000 : 1_000_000
    return String(format: "%0*u", digits, truncated % divisor)
  }
}

extension HostStore {
  /// One tap, one key. It is this device's, and the next sync gives the same
  /// key to the other devices on this Apple ID. It only logs in once the
  /// server has been told its public half.
  func generateKey(for host: Host) {
    do {
      guard host.profile != nil else { throw IdentityError.invalidConfiguration }
      let secretID = Self.syncedKeyID(for: host.id)
      let publicKey = try credentials.generateSSHKey(id: secretID, label: host.label)
      do {
        try update { state in
          guard var record = state.records[host.id], !record.deleted else { throw IdentityError.needsReview }
          let credential = record.profile.authentication.primary.id
          state.bindings[credential] = LocalCredentialBinding(credentialID: credential, secretID: secretID, publicKey: publicKey)
          record.dirty = true
          record.syncedKeyDigest = nil
          record.forgetSharedKey = nil
          state.records[host.id] = record
        }
        scheduleSync()
      } catch {
        try? credentials.forget(secretID)
        throw error
      }
    } catch { recordProblem(error) }
  }

  func setOTP(_ text: String, for host: Host) {
    do {
      guard var profile = host.profile else { throw IdentityError.invalidConfiguration }
      let otp = try TOTP(importing: text)
      let descriptor = profile.authentication.otp ?? .oneTimeCode(for: profile)
      let secretID = UUID()
      try credentials.write(String(decoding: JSONEncoder().encode(otp), as: UTF8.self), id: secretID, label: host.label + " OTP")
      profile.authentication.otp = descriptor
      profile.authentication.confirmation = .confirmAuthentication
      let selected = profile
      try update { state in
        guard var record = state.records[host.id], !record.deleted, record.conflicts.isEmpty else { throw IdentityError.needsReview }
        record.profile = selected; record.dirty = true; state.records[host.id] = record
        state.bindings[descriptor.id] = LocalCredentialBinding(credentialID: descriptor.id, secretID: secretID)
        state.approvals[host.id] = selected.securityDigest
      }
      scheduleSync()
    } catch { recordProblem(error) }
  }
}
