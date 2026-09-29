import Foundation

/// What a host is, as far as both `~/.ssh/config` and the library can say
/// it: the name, and where and as whom it is reached.
struct HostFace: Codable, Hashable, Sendable {
  var name: String
  var hostName: String
  var user: String
  var port: UInt16

  init(name: String, hostName: String, user: String, port: UInt16) {
    self.name = name
    self.hostName = hostName
    self.user = user
    self.port = port
  }

  init(_ entry: SSHConfig.Entry, defaultUser: String) {
    self.init(name: entry.alias, hostName: entry.hostName, user: entry.user ?? defaultUser, port: entry.port ?? 22)
  }

  init(_ profile: HostProfile) {
    self.init(name: profile.label, hostName: profile.hostname, user: profile.username, port: profile.port)
  }

  /// The same machine and account, whatever it is called.
  func sameAddress(as other: HostFace) -> Bool {
    hostName == other.hostName && user == other.user && port == other.port
  }
}

/// Which library host a stanza of this Mac's SSH configuration became, and
/// what the stanza said when it was last read — the reference that tells a
/// stanza someone edited from one nobody touched.
struct ImportLink: Codable, Hashable, Sendable {
  var id: UUID
  var file: String
  var seen: HostFace?
}

/// How this Mac's SSH configuration feeds the library.
///
/// The library is the one source of truth; the configuration is where hosts
/// come from on a Mac, never where they go. A stanza the library has not seen
/// is added; a stanza someone edited updates its host; a host changed or
/// deleted in Tether stays as Tether left it for as long as its stanza is not
/// edited again; a stanza taken out of the file takes nothing out of the
/// library. Nothing is ever written back.
///
/// Pure: it looks at what the file says, what the library says and what the
/// file said last time, and says what to do. `HostStore` does it.
enum ConfigImport {
  enum Step: Equatable {
    /// Not in the library yet: add it.
    case add(SSHConfig.Entry)
    /// The stanza was edited: its host takes what it says now.
    case take(SSHConfig.Entry, id: UUID, replacing: String?)
    /// Linked; the library's host stands as it is.
    case keep(SSHConfig.Entry, id: UUID)
    /// The link no longer means anything.
    case forget(alias: String)
  }

  struct Input {
    var entries: [SSHConfig.Entry]
    var modified: [String: Date]
    var records: [UUID: SharedHostRecord]
    var links: [String: ImportLink]
    var defaultUser: String
  }

  static func plan(_ input: Input) -> [Step] {
    var steps: [Step] = []
    let present = Set(input.entries.map(\.alias))
    var claimed = Set(input.links.values.map(\.id))
    var gone = input.links.filter { !present.contains($0.key) }

    for entry in input.entries {
      let face = HostFace(entry, defaultUser: input.defaultUser)
      if let link = input.links[entry.alias] {
        guard let record = input.records[link.id], record.vanished != true else {
          // Its host went with an iCloud reset, or is gone altogether: the
          // stanza brings it back as it is written.
          steps.append(.forget(alias: entry.alias))
          claimed.remove(link.id)
          steps.append(.add(entry))
          continue
        }
        if record.deleted {
          // Deleted in Tether. It stays deleted until someone edits the
          // stanza — which is someone asking for the host again.
          if link.seen != face {
            steps.append(.forget(alias: entry.alias))
            steps.append(.add(entry))
          }
          continue
        }
        steps.append(decide(entry, face: face, record: record, seen: link.seen, input: input))
        continue
      }

      // A name changed in the file: the stanza that left the same file with
      // the same address is this one, renamed.
      if let (alias, link) = gone.first(where: { _, link in
        link.file == entry.file && input.records[link.id].map { !$0.deleted && HostFace($0.profile).sameAddress(as: face) } == true
      }) {
        gone.removeValue(forKey: alias)
        steps.append(.take(entry, id: link.id, replacing: alias))
        continue
      }

      // The same name another device added is the same host.
      if let record = input.records.values.first(where: {
        !$0.deleted && $0.profile.label == entry.alias && !claimed.contains($0.profile.id)
      }) {
        claimed.insert(record.profile.id)
        steps.append(decide(entry, face: face, record: record, seen: nil, input: input))
        continue
      }
      steps.append(.add(entry))
    }

    // A stanza taken out of the file takes nothing out of the library.
    for alias in gone.keys.sorted() { steps.append(.forget(alias: alias)) }
    return steps
  }

  /// Whether an edited stanza updates its host. Only an edited one: a stanza
  /// nobody touched never undoes a change made in Tether. When both changed,
  /// the one changed last wins.
  private static func decide(
    _ entry: SSHConfig.Entry, face: HostFace, record: SharedHostRecord, seen: HostFace?, input: Input
  ) -> Step {
    let id = record.profile.id
    let library = HostFace(record.profile)
    if library == face || seen == face { return .keep(entry, id: id) }
    let libraryChanged = seen.map { $0 != library } ?? true
    if !libraryChanged { return .take(entry, id: id, replacing: nil) }
    let fileTime = entry.file.flatMap { input.modified[$0] } ?? .distantPast
    return fileTime > (record.profile.modified ?? .distantPast)
      ? .take(entry, id: id, replacing: nil) : .keep(entry, id: id)
  }
}
