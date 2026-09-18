import Foundation

/// Who to suggest as the remote user.
///
/// A Mac account name is usually the right guess. A phone has no such thing —
/// `mobile` is the simulator's account, not the person's — so the field is
/// left empty rather than prefilled with a name that would have to be
/// deleted every time.
func defaultUserName() -> String {
  #if os(macOS)
    NSUserName()
  #else
    ""
  #endif
}
import Observation

/// A host someone saved.
///
/// `label` is separate from `hostname` because the two answer different
/// questions: one is what a person calls the machine, the other is how to
/// reach it. Collapsing them is why some clients show a list of IP addresses.
struct Host: Identifiable, Codable, Hashable {
  var id = UUID()
  var label: String
  var hostname: String
  var port: UInt16
  var username: String
  /// Where the private key lives, when this host uses one.
  ///
  /// A path, not the key: the file stays where the person put it, with the
  /// permissions they gave it, and Tether reads it at the moment of
  /// connecting rather than keeping a copy (spec §18).
  var keyPath: String?

  /// What the sidebar shows under the label.
  var address: String {
    port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
  }

  /// The letter on the tile.
  var initial: String {
    let source = label.isEmpty ? hostname : label
    return source.first.map { String($0).uppercased() } ?? "?"
  }

  static func blank() -> Host {
    Host(label: "", hostname: "", port: 22, username: defaultUserName(), keyPath: nil)
  }
}

/// The saved hosts, on disk.
///
/// No passwords and no keys. A keychain integration is a real feature with
/// real consequences, and a JSON file pretending to be one would be worse
/// than asking every time (spec §18).
@MainActor
@Observable
final class HostStore {
  private(set) var hosts: [Host] = []
  var search: String = ""

  private let location: URL

  var filtered: [Host] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return hosts }
    return hosts.filter {
      $0.label.lowercased().contains(query)
        || $0.hostname.lowercased().contains(query)
        || $0.username.lowercased().contains(query)
    }
  }

  init(location override: URL? = nil) {
    if let override {
      location = override
      load()
      return
    }
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let directory = support.appending(path: "Tether", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    location = directory.appending(path: "hosts.json")
    load()
  }

  func save(_ host: Host) {
    if let index = hosts.firstIndex(where: { $0.id == host.id }) {
      hosts[index] = host
    } else {
      hosts.append(host)
    }
    persist()
  }

  func delete(_ host: Host) {
    hosts.removeAll { $0.id == host.id }
    persist()
  }

  private func load() {
    guard let data = try? Data(contentsOf: location) else { return }

    if let decoded = try? JSONDecoder().decode([Host].self, from: data) {
      hosts = decoded
      return
    }

    // A file that will not decode is moved aside, not overwritten. The
    // next save would otherwise replace someone's hosts with an empty
    // list, and the only copy of them is this file.
    let aside = location.appendingPathExtension("unreadable")
    try? FileManager.default.removeItem(at: aside)
    try? FileManager.default.moveItem(at: location, to: aside)
    hosts = []
  }

  private func persist() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(hosts) else { return }
    try? data.write(to: location, options: .atomic)
  }
}
