import Foundation

/// A host's password and one-time-code seed travel with it, as its private
/// key does: sent with the host's record when they change here, installed
/// when they arrive, withdrawn everywhere when a person lets go of them.
/// Each keychain item stays on its device; what crosses is the record's
/// encrypted field (`HostCloudSync`). Nothing here is logged.
extension HostStore {
  /// Where a shared password or code seed is kept on every device: one id
  /// per host, so a copy that arrives twice lands on the item already there.
  static func syncedPasswordID(for host: UUID) -> UUID { nameBasedUUID("synced-password:" + host.uuidString) }
  static func syncedCodeID(for host: UUID) -> UUID { nameBasedUUID("synced-code:" + host.uuidString) }

  /// The longest password taken from another device or a password manager.
  static let passwordLimit = 4096

  /// The password this device logs in to the host with.
  func sharedPassword(for profile: HostProfile) -> String? {
    sharedPassword(for: profile.id, in: snapshot)
  }

  /// The code seed this device answers the host's challenge with, as stored.
  func sharedCode(for profile: HostProfile) -> String? {
    sharedCode(for: profile, in: snapshot)
  }

  func sharedPassword(for id: UUID, in state: IdentitySnapshot) -> String? {
    guard let item = state.passwordBindings[id], let password = try? secrets.password(for: item),
      !password.isEmpty, password.utf8.count <= Self.passwordLimit else { return nil }
    return password
  }

  func sharedCode(for profile: HostProfile, in state: IdentitySnapshot) -> String? {
    guard let otp = profile.authentication.otp, let item = state.bindings[otp.id]?.secretID,
      let text = try? credentials.read(item), let code = try? TOTP(stored: text) else { return nil }
    return code.stored
  }

  /// Whether the host has a password or code seed the other devices have
  /// not been sent, or one they are still to be told to let go of.
  func secretsAwaitSync(_ record: SharedHostRecord, in state: IdentitySnapshot) -> Bool {
    if record.forgetSharedPassword == true || record.forgetSharedCode == true { return true }
    if let password = sharedPassword(for: record.profile.id, in: state),
      record.syncedPasswordDigest != Self.keyDigest(password) { return true }
    if let code = sharedCode(for: record.profile, in: state),
      record.syncedCodeDigest != Self.keyDigest(code) { return true }
    return false
  }

  /// What the record that was just saved carried — read from the record,
  /// not from the keychain, which may have changed while it was on its way.
  /// `nil` is a field the record did not carry; `""` a withdrawal delivered.
  static func didSendSecrets(_ record: inout SharedHostRecord, password: String?, code: String?) {
    if let password {
      if password.isEmpty { record.forgetSharedPassword = nil }
      record.syncedPasswordDigest = password.isEmpty ? clearedKey : keyDigest(password)
    }
    if let code {
      if code.isEmpty { record.forgetSharedCode = nil }
      record.syncedCodeDigest = code.isEmpty ? clearedKey : keyDigest(code)
    }
  }

  /// Whether this device holds a value it has not sent yet: one kept here
  /// since the last value it sent or received. Such a value wins over what
  /// arrives, and goes out with the next sync.
  private static func isUnsent(_ current: String?, synced: String?) -> Bool {
    guard let current else { return false }
    return keyDigest(current) != synced
  }

  /// `nil` leaves this device's password alone; `""` withdraws the shared
  /// one; anything else is the host's password now — unless this device has
  /// kept a newer one it has not sent yet.
  func takePassword(_ password: String?, for id: UUID, in state: inout IdentitySnapshot) throws {
    guard var record = state.records[id], !record.deleted, let password else { return }
    let current = sharedPassword(for: id, in: state)
    if Self.isUnsent(current, synced: record.syncedPasswordDigest), current != password { return }
    if password.isEmpty {
      state.passwordBindings[id] = nil
      record.forgetSharedPassword = nil
      record.syncedPasswordDigest = Self.clearedKey
      state.records[id] = record
      return
    }
    guard password.utf8.count <= Self.passwordLimit else { return }
    record.syncedPasswordDigest = Self.keyDigest(password)
    record.forgetSharedPassword = nil
    state.records[id] = record
    if current == password { return }
    let item = Self.syncedPasswordID(for: id)
    let profile = record.profile
    try secrets.remember(password, for: Host(id: item, label: profile.label, hostname: profile.hostname,
      port: profile.port, username: profile.username))
    notePassword(item, kept: true)
    state.passwordBindings[id] = item
  }

  /// The same for a code seed, which only a host that asks for a code has
  /// anywhere to put. A seed that does not read as one is ignored.
  func takeCode(_ code: String?, for id: UUID, in state: inout IdentitySnapshot) throws {
    guard var record = state.records[id], !record.deleted, let code,
      let otp = record.profile.authentication.otp else { return }
    let current = sharedCode(for: record.profile, in: state)
    if Self.isUnsent(current, synced: record.syncedCodeDigest), current != code { return }
    if code.isEmpty {
      state.bindings[otp.id] = nil
      record.forgetSharedCode = nil
      record.syncedCodeDigest = Self.clearedKey
      state.records[id] = record
      return
    }
    guard let seed = try? TOTP(stored: code) else { return }
    record.syncedCodeDigest = Self.keyDigest(seed.stored)
    record.forgetSharedCode = nil
    state.records[id] = record
    if current == seed.stored { return }
    let item = Self.syncedCodeID(for: id)
    try credentials.write(seed.stored, id: item, label: record.profile.label + " OTP")
    state.bindings[otp.id] = LocalCredentialBinding(credentialID: otp.id, secretID: item)
  }

  /// A saved password removed from the list in Settings is removed from the
  /// host, and from the other devices.
  func withdrawPassword(boundTo item: UUID) {
    guard let host = snapshot.passwordBindings.first(where: { $0.value == item })?.key else { return }
    do {
      try update { state in
        state.passwordBindings[host] = nil
        guard var record = state.records[host], !record.deleted else { return }
        record.forgetSharedPassword = true
        record.dirty = true
        state.records[host] = record
      }
      scheduleSync()
    } catch { recordProblem(error) }
  }

  /// Keeps what a person chose from a password manager's export, each on
  /// the host they chose it for. Nothing they left unchosen is stored. The
  /// next sync carries what was kept to their other devices.
  func adopt(_ choices: [CredentialExchange.Choice]) {
    var failure: Error?
    for choice in choices where choice.takesAnything {
      guard let id = choice.host, let host = hosts.first(where: { $0.id == id }) else { continue }
      let secrets = choice.item.secrets
      do {
        if choice.password, let password = secrets.password { try adoptPassword(password, for: host) }
        if choice.privateKey, let pem = secrets.privateKey { try adoptKey(pem, for: host) }
        if choice.code, let code = secrets.code {
          guard let current = hosts.first(where: { $0.id == id }) else { continue }
          try setOTP(code, for: current)
        }
      } catch { failure = failure ?? error }
    }
    if let failure { recordProblem(failure) }
    scheduleSync()
  }

  private func adoptPassword(_ password: String, for host: Host) throws {
    guard password.utf8.count <= Self.passwordLimit else { throw IdentityError.invalidConfiguration }
    let item = snapshot.passwordBindings[host.id] ?? UUID()
    var target = host
    target.id = item
    try secrets.remember(password, for: target)
    notePassword(item, kept: true)
    try update { state in
      guard var record = state.records[host.id], !record.deleted else { throw IdentityError.needsReview }
      record.forgetSharedPassword = nil
      state.records[host.id] = record
      state.passwordBindings[host.id] = item
    }
  }

  private func adoptKey(_ pem: String, for host: Host) throws {
    guard Self.looksLikePrivateKey(pem) else { throw IdentityError.invalidConfiguration }
    let item = Self.syncedKeyID(for: host.id)
    try credentials.write(pem, id: item, label: host.label)
    try update { state in
      guard var record = state.records[host.id], !record.deleted else { throw IdentityError.needsReview }
      let credential = record.profile.authentication.primary.id
      state.bindings[credential] = LocalCredentialBinding(credentialID: credential, secretID: item)
      record.dirty = true
      record.syncedKeyDigest = nil
      record.forgetSharedKey = nil
      state.records[host.id] = record
    }
  }
}
