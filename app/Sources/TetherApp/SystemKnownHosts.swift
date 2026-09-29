import CryptoKit
import Foundation
import Tether

/// What system ssh already knows about a server's key, from its
/// `known_hosts` file.
///
/// Read, never written, like `~/.ssh/config`. A host someone has reached with
/// `ssh` for years has been vouched for already; asking again here is the
/// prompt that teaches people to click through prompts. And a key that
/// differs from the one ssh recorded is exactly as alarming here as it would
/// be there.
struct SystemKnownHosts {
  enum Verdict: Equatable {
    /// ssh has this key for this endpoint.
    case trusted
    /// ssh has a different key of the same kind for this endpoint, or has
    /// revoked this one.
    case changed(KnownHost)
  }

  private struct Line {
    var revoked: Bool
    var hosts: String
    var algorithm: String
    var fingerprint: String
  }

  private let lines: [Line]

  init(_ text: String) {
    lines = text.components(separatedBy: .newlines).compactMap(Self.parse)
  }

  /// The file at `url`, or nothing if there is none to read.
  init(contentsOf url: URL) {
    self.init((try? String(contentsOf: url, encoding: .utf8)) ?? "")
  }

  /// `nil` when ssh has no opinion: never seen, or seen only with keys of
  /// other kinds — which is also a question ssh would ask.
  func verdict(for identity: HostIdentity) -> Verdict? {
    let name = Self.name(identity)
    let relevant = lines.filter { Self.names(name, in: $0.hosts) }
    if let revoked = revocation(of: identity) { return .changed(revoked) }
    if relevant.contains(where: { !$0.revoked && $0.fingerprint == identity.fingerprint }) {
      return .trusted
    }
    if let other = relevant.first(where: { !$0.revoked && $0.algorithm == identity.algorithm }) {
      return .changed(KnownHost(endpoint: KnownHosts.endpoint(identity), algorithm: other.algorithm,
        fingerprint: other.fingerprint, source: "known_hosts"))
    }
    return nil
  }

  /// This exact key, marked `@revoked` for this endpoint. Absolute, as it is
  /// to ssh: no earlier acceptance outranks it.
  func revocation(of identity: HostIdentity) -> KnownHost? {
    let name = Self.name(identity)
    guard lines.contains(where: { $0.revoked && $0.fingerprint == identity.fingerprint && Self.names(name, in: $0.hosts) })
    else { return nil }
    return KnownHost(endpoint: KnownHosts.endpoint(identity), algorithm: identity.algorithm,
      fingerprint: identity.fingerprint, source: "known_hosts")
  }

  /// How `known_hosts` spells an endpoint.
  private static func name(_ identity: HostIdentity) -> String {
    identity.port == 22 ? identity.host.lowercased() : "[\(identity.host.lowercased())]:\(identity.port)"
  }

  /// `[marker] hosts keytype base64 [comment]`. Certificate authorities vouch
  /// for keys by signature, which this does not check, so their lines are
  /// left out rather than half-understood.
  private static func parse(_ raw: String) -> Line? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
    var fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    var revoked = false
    if let marker = fields.first, marker.hasPrefix("@") {
      guard marker == "@revoked" else { return nil }
      revoked = true
      fields.removeFirst()
    }
    guard fields.count >= 3, let blob = Data(base64Encoded: fields[2]) else { return nil }
    return Line(revoked: revoked, hosts: fields[0], algorithm: fields[1], fingerprint: fingerprint(blob))
  }

  /// The form ssh prints and the SDK reports: `SHA256:` and unpadded base64.
  static func fingerprint(_ blob: Data) -> String {
    "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }

  /// A comma-separated pattern list, or one `HashKnownHosts` entry:
  /// `|1|salt|HMAC-SHA1(salt, name)`.
  private static func names(_ name: String, in hosts: String) -> Bool {
    if hosts.hasPrefix("|1|") {
      let parts = hosts.split(separator: "|", omittingEmptySubsequences: false)
      guard parts.count == 4, let salt = Data(base64Encoded: String(parts[2])),
        let hash = Data(base64Encoded: String(parts[3])) else { return false }
      let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
      return Data(code) == hash
    }
    return sshPatternsMatch(hosts.lowercased().split(separator: ",").map(String.init), name)
  }
}
