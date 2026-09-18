import Foundation
import Observation
import Tether

/// A host key someone already accepted.
struct KnownHost: Codable, Hashable {
  /// `host:port` — the thing a key belongs to. A key is trusted *for an
  /// endpoint*, not in general, so this is half of the identity.
  var endpoint: String
  var algorithm: String
  var fingerprint: String
}

/// What a person is being asked, when they are asked at all.
enum TrustQuestion {
  /// Never seen this endpoint before.
  case unknown
  /// Seen it, and the key is not the one recorded.
  ///
  /// The dangerous case, and the whole reason a record is kept: a key that
  /// changes under a host is either an administrator rotating it or someone
  /// standing in the middle, and only the person can tell which.
  case changed(from: KnownHost)
}

/// The keys this app has accepted, across launches.
///
/// Asking again for a host someone already vouched for trains them to accept
/// without reading, which is the failure mode the prompt exists to prevent.
/// Remembering is what makes the *second* prompt mean something.
///
/// Fingerprints only. A fingerprint is public — it is what an administrator
/// publishes — so this file discloses nothing, and it deliberately holds no
/// credential of any kind (spec §18).
@MainActor
@Observable
final class KnownHosts {
  private(set) var entries: [KnownHost] = []
  private let location: URL

  init(location: URL? = nil) {
    if let location {
      self.location = location
    } else {
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
      let directory = support.appending(path: "Tether", directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      self.location = directory.appending(path: "known_hosts.json")
    }
    load()
  }

  /// `nil` when the key is already trusted for this endpoint and nobody needs
  /// to be asked.
  func question(for host: HostIdentity) -> TrustQuestion? {
    let endpoint = Self.endpoint(host)
    guard let recorded = entries.first(where: { $0.endpoint == endpoint }) else {
      return .unknown
    }
    if recorded.fingerprint == host.fingerprint { return nil }
    return .changed(from: recorded)
  }

  /// Records an acceptance, replacing any earlier key for that endpoint.
  func remember(_ host: HostIdentity) {
    let entry = KnownHost(
      endpoint: Self.endpoint(host),
      algorithm: host.algorithm,
      fingerprint: host.fingerprint)

    entries.removeAll { $0.endpoint == entry.endpoint }
    entries.append(entry)
    persist()
  }

  func forget(_ endpoint: String) {
    entries.removeAll { $0.endpoint == endpoint }
    persist()
  }

  /// The default port is written out rather than elided: `example.org` and
  /// `example.org:22` would otherwise be two endpoints with one key between
  /// them, and the mismatch check would never fire.
  static func endpoint(_ host: HostIdentity) -> String { "\(host.host):\(host.port)" }

  private func load() {
    guard let data = try? Data(contentsOf: location) else { return }
    if let decoded = try? JSONDecoder().decode([KnownHost].self, from: data) {
      entries = decoded
      return
    }

    // A file that will not decode is moved aside rather than overwritten.
    // Losing it silently would turn every host back into an unknown one, and
    // a prompt that returns for no reason is a prompt people stop reading.
    let aside = location.appendingPathExtension("unreadable")
    try? FileManager.default.removeItem(at: aside)
    try? FileManager.default.moveItem(at: location, to: aside)
    entries = []
  }

  private func persist() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(entries) else { return }
    try? data.write(to: location, options: .atomic)
  }
}
