import Foundation
import Security

/// A password someone asked this app to keep.
///
/// Identified by the host's `id` rather than by its address: a host that gets
/// renamed, moved to another port or pointed at a new address is still the
/// same saved host, and a person who said "remember this" did not mean "until
/// the address changes". The address is kept only as a label, for the list in
/// settings and for whoever opens Keychain Access and wonders what this is.
struct SavedSecret: Identifiable, Hashable {
  let id: UUID
  let label: String
}

enum SecretError: LocalizedError {
  case refused(OSStatus)

  var errorDescription: String? {
    switch self {
    case .refused(let status):
      let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
      return "The keychain refused: \(detail)"
    }
  }
}

/// Where passwords live, for the code that does not care which keychain it is.
///
/// A protocol so the app can be tested without touching the login keychain —
/// a unit test that asks for one gets a prompt on a developer's machine and a
/// failure on a build server, which is how a keychain test becomes a deleted
/// keychain test.
protocol SecretStore: Sendable {
  /// `nil` when nothing is stored, which is not an error.
  func password(for host: UUID) throws -> String?
  func remember(_ password: String, for host: Host) throws
  func forget(_ host: UUID) throws
  /// Everything this store holds, for the one screen that lists it.
  func saved() throws -> [SavedSecret]
}

/// The system keychain.
///
/// The only credential store in this app. The alternative — a file beside
/// `hosts.json` — is what spec §18 rules out and what `HostStore` says it is
/// not: a JSON file pretending to be a keychain is worse than asking every
/// time, because it looks like security to the person trusting it.
///
/// Items are `WhenUnlockedThisDeviceOnly` and not synchronizable: a password
/// saved here does not reach iCloud, another Mac, or a backup that a person
/// did not think of as holding their server passwords.
struct Keychain: SecretStore {
  /// One service for the whole app, so `saved()` can enumerate what it owns
  /// without walking a person's entire keychain.
  let service: String
  let dataProtection: Bool

  init(service: String = (Bundle.main.bundleIdentifier ?? "app.tether") + ".host-password", dataProtection: Bool = true) {
    self.service = service
    self.dataProtection = dataProtection
  }

  func password(for host: UUID) throws -> String? {
    var query = base(host)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      // Read-only compatibility with passwords saved in the legacy macOS keychain.
      #if os(macOS)
      if dataProtection { return try Keychain(service: service, dataProtection: false).password(for: host) }
      #endif
      return nil
    }
    guard status == errSecSuccess else { throw SecretError.refused(status) }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func remember(_ password: String, for host: Host) throws {
    let changes: [String: Any] = [
      kSecValueData as String: Data(password.utf8),
      kSecAttrLabel as String: "Tether — \(host.address)",
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
    let updated = SecItemUpdate(base(host.id) as CFDictionary, changes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw SecretError.refused(updated) }
    var item = base(host.id)
    item.merge(changes) { _, new in new }
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw SecretError.refused(status) }
  }

  func forget(_ host: UUID) throws {
    let status = SecItemDelete(base(host) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretError.refused(status)
    }
    #if os(macOS)
    if dataProtection { try Keychain(service: service, dataProtection: false).forget(host) }
    #endif
  }

  func saved() throws -> [SavedSecret] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
    // Never the data. This list exists so someone can delete a password, and
    // reading every password to draw a list of them would be the opposite of
    // the point.
    query[kSecReturnData as String] = false

    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretError.refused(status) }

    var result: [SavedSecret] = (items as? [[String: Any]] ?? []).compactMap { attributes in
      guard let account = attributes[kSecAttrAccount as String] as? String,
        let id = UUID(uuidString: account)
      else { return nil }
      let label = attributes[kSecAttrLabel as String] as? String
      return SavedSecret(id: id, label: label ?? account)
    }
    #if os(macOS)
    if dataProtection {
      let legacy = try Keychain(service: service, dataProtection: false).saved()
      let existing = Set(result.map(\.id))
      result += legacy.filter { !existing.contains($0.id) }
    }
    #endif
    return result
  }

  private func base(_ host: UUID) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: host.uuidString,
    ]
    if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
    return query
  }
}
