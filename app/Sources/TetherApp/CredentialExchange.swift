import AuthenticationServices
import Foundation

/// What a password manager handed over (Credential Exchange), reduced to
/// what a host can log in with: a password, a one-time-code seed, a private
/// key. Everything else in an export — passkeys, cards, notes, the items
/// that match no host — is dropped here, in memory, and never stored.
enum CredentialExchange {
  /// The secrets one exported item carries for a host.
  struct Secrets: Equatable, Sendable {
    var password: String?
    var code: TOTP?
    var privateKey: String?

    var isEmpty: Bool { password == nil && code == nil && privateKey == nil }
  }

  /// One exported item that carries something a host can use.
  struct Item: Identifiable, Equatable, Sendable {
    let id: Data
    let title: String
    let userName: String?
    /// The item's title and the hosts of its URLs, folded for comparison.
    let names: Set<String>
    let secrets: Secrets
  }

  /// An item and the host it would go to. The person decides what is kept.
  struct Choice: Identifiable, Equatable, Sendable {
    var id: Data { item.id }
    let item: Item
    var host: UUID?
    var password: Bool
    var code: Bool
    var privateKey: Bool

    var takesAnything: Bool { host != nil && (password || code || privateKey) }
  }

  static func items(in data: ASExportedCredentialData) -> [Item] {
    data.accounts.flatMap(\.items).compactMap(item)
  }

  /// Every item paired with the one host it names, or with none. An item
  /// names a host when its title or a URL's host is the host's name or
  /// address, and its user name is the host's — a shared name alone, with
  /// another account, is somebody else's login. Two items naming one host
  /// leave it to the person.
  static func choices(for items: [Item], hosts: [Host]) -> [Choice] {
    var claimed: [UUID: Int] = [:]
    let matches = items.map { item -> UUID? in
      let found = hosts.filter { matches(item, $0) }
      guard found.count == 1, let host = found.first else { return nil }
      claimed[host.id, default: 0] += 1
      return host.id
    }
    return zip(items, matches).map { item, match in
      let host = match.flatMap { claimed[$0] == 1 ? $0 : nil }
      return choice(item, for: host.flatMap { id in hosts.first { $0.id == id } })
    }
  }

  /// The item on that host, choosing what the host does not have yet. What
  /// it has is replaced only when the person turns it on.
  static func choice(_ item: Item, for host: Host?) -> Choice {
    Choice(item: item, host: host?.id,
      password: item.secrets.password != nil && host?.remembersPassword != true,
      code: item.secrets.code != nil && host?.otpSecretID == nil,
      privateKey: item.secrets.privateKey != nil && host.map(hasKey) != true)
  }

  static func matches(_ item: Item, _ host: Host) -> Bool {
    guard !host.isLocal, let user = item.userName, user == host.username else { return false }
    return !item.names.isDisjoint(with: [fold(host.label), fold(host.hostname)].filter { !$0.isEmpty })
  }

  /// Whether the host already logs in with a key of this device's.
  static func hasKey(_ host: Host) -> Bool {
    host.credentialSecretID != nil || host.keyPath != nil || host.usesDefaultKeys
  }

  private static func item(_ item: ASImportableItem) -> Item? {
    var secrets = Secrets()
    var users: [String] = []
    for credential in item.credentials {
      switch credential {
      case .basicAuthentication(let login):
        if let user = login.userName?.value, !user.isEmpty { users.append(user) }
        if let password = login.password?.value, !password.isEmpty, password.utf8.count <= 4096 {
          secrets.password = secrets.password ?? password
        }
      case .totp(let totp):
        if let user = totp.userName, !user.isEmpty { users.append(user) }
        if let algorithm = algorithm(totp.algorithm),
          let code = try? TOTP(secret: totp.secret, algorithm: algorithm, digits: Int(totp.digits), period: Int(totp.period)) {
          secrets.code = secrets.code ?? code
        }
      case .sshKey(let key):
        secrets.privateKey = secrets.privateKey ?? privateKey(key.privateKey)
      default:
        continue
      }
    }
    guard !secrets.isEmpty else { return nil }
    let hosts = (item.scope?.urls ?? []).compactMap { $0.host() ?? URL(string: "ssh://" + $0.absoluteString)?.host() }
    let names = Set(([item.title] + hosts).map(fold).filter { !$0.isEmpty })
    return Item(id: item.id, title: item.title, userName: users.first, names: names, secrets: secrets)
  }

  private static func algorithm(_ algorithm: ASImportableCredential.TOTP.Algorithm) -> TOTP.Algorithm? {
    switch algorithm {
    case .sha1: .sha1
    case .sha256: .sha256
    case .sha512: .sha512
    @unknown default: nil
    }
  }

  /// The format names the key PKCS#8 DER; a manager that hands over the
  /// text of a key file instead is taken at its word too. Either way it is
  /// PEM by the time it reaches the keychain, as every other key there is.
  static func privateKey(_ data: Data) -> String? {
    if let text = String(data: data, encoding: .utf8), HostStore.looksLikePrivateKey(text) {
      return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
    guard !data.isEmpty, data.count <= 16 * 1024, data.first == 0x30 else { return nil }
    let body = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN PRIVATE KEY-----\n\(body)\n-----END PRIVATE KEY-----\n"
  }

  private static func fold(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
