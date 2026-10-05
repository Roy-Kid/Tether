import Foundation

/// What an import from this Mac's SSH configuration would change.
struct ConfigurationImport: Equatable, Hashable {
  /// The file the changes were read from, with the home directory as `~`.
  /// Several files: the configuration that included them.
  var source: String
  /// When that file was last written. The newest, when several changed.
  var modified: Date?
  /// What Import would write over the library, as a unified diff.
  var diff: String
  var names: [String]

  /// Where it comes from.
  var title: String { source }

  /// When it was last written.
  var message: String? {
    modified?.formatted(date: .abbreviated, time: .shortened)
  }
}

/// This Mac's SSH configuration, read into the library.
///
/// `ConfigImport` decides a quiet read: an edited stanza updates its host,
/// and a stanza nobody touched never undoes a change made in Tether.
/// Opening asks before the other read, the one that copies the file over
/// the hosts it names. Either read only writes the library. The file stays
/// where it is.
extension HostStore {
  /// Which library host each of this Mac's stanzas became.
  var links: [String: ImportLink] {
    snapshot.imports ?? Dictionary(uniqueKeysWithValues: snapshot.adoptedAliases.map {
      ($0.key, ImportLink(id: $0.value, file: location.path, seen: nil))
    })
  }

  /// Reads what changed in the configuration into the library. Safe to call
  /// often: when nothing changed it writes nothing.
  func reconcile() {
    #if os(macOS)
      guard !unreadable else { return }
      let steps = ConfigImport.plan(.init(
        entries: config.entries, modified: Self.modificationDates(of: config.files),
        records: snapshot.records, links: links, defaultUser: defaultUserName()))
      do {
        try apply(steps)
        scheduleSync()
      } catch { recordProblem(error) }
    #endif
  }

  /// Asks, when the file would change a host, whether to copy it over the
  /// library. Called once, when the app opens. Declining leaves both as
  /// they are.
  func offerConfigurationImport() {
    #if os(macOS)
      guard !unreadable else { return }
      reload()
      guard let offer = configurationOffer() else {
        pendingImport = nil
        return
      }
      if offer.diff == declinedImport || offer.diff == pendingImport?.diff { return }
      pendingImport = offer
    #endif
  }

  func declineConfigurationImport() {
    declinedImport = pendingImport?.diff
    pendingImport = nil
  }

  func acceptConfigurationImport() {
    importConfiguration()
  }

  /// Copies `~/.ssh/config` over the hosts it names. A host the file does
  /// not name stays. The file is not modified.
  func importConfiguration() {
    #if os(macOS)
      guard !unreadable else { return }
      reload()
      var steps: [ConfigImport.Step] = []
      for entry in config.entries {
        if let match = match(for: entry) {
          if match.deleted || differs(entry, match.record) {
            steps.append(.take(entry, id: match.id, replacing: match.replacing))
          } else {
            steps.append(.keep(entry, id: match.id))
          }
        } else {
          steps.append(.add(entry))
        }
      }
      let reviving = steps.compactMap { step -> UUID? in
        guard case .take(_, let id, _) = step, let record = snapshot.records[id] else { return nil }
        return record.deleted || !record.conflicts.isEmpty ? id : nil
      }
      do {
        if !reviving.isEmpty {
          try update { state in
            for id in reviving {
              state.records[id]?.deleted = false
              state.records[id]?.conflicts = [:]
            }
          }
        }
        try apply(steps)
        scheduleSync()
        pendingImport = nil
        declinedImport = nil
      } catch { recordProblem(error) }
    #endif
  }

  /// The offer, or nothing when the file and the library already agree.
  private func configurationOffer() -> ConfigurationImport? {
    struct Change {
      var file: String?
      var name: String
      var hunk: String
    }
    var changes: [Change] = []
    for entry in config.entries {
      guard let hunk = diff(for: entry) else { continue }
      changes.append(Change(file: entry.file, name: entry.alias, hunk: hunk))
    }
    guard !changes.isEmpty else { return nil }
    var files: [String] = []
    for change in changes {
      if let file = change.file, !files.contains(file) { files.append(file) }
    }
    let dates = Self.modificationDates(of: Set(files))
    let source = files.count == 1 ? files[0] : location.path
    let body: String
    if files.count <= 1 {
      body = changes.map(\.hunk).joined(separator: "\n")
    } else {
      body = changes.map { change in
        let path = Self.abbreviate(change.file ?? location.path)
        let when = change.file.flatMap { dates[$0] }?.formatted(date: .abbreviated, time: .shortened)
        return [path, when].compactMap { $0 }.joined(separator: "  ") + "\n" + change.hunk
      }.joined(separator: "\n")
    }
    return ConfigurationImport(
      source: Self.abbreviate(source), modified: files.compactMap { dates[$0] }.max(),
      diff: body, names: changes.map(\.name))
  }

  /// One host, as a unified diff of the settings Import would copy.
  /// Nothing, when copying the stanza would leave the library as it is.
  private func diff(for entry: SSHConfig.Entry) -> String? {
    let limits = unsupported(entry) ?? []
    guard let match = match(for: entry), !match.deleted else {
      return added(entry, limits: limits)
    }
    let record = match.record
    let library = HostFace(record.profile)
    let file = HostFace(entry, defaultUser: defaultUserName())
    var lines: [String] = []
    if library.name != file.name {
      lines.append("-Host \(library.name)")
      lines.append("+Host \(file.name)")
    } else {
      lines.append(" Host \(file.name)")
    }
    func setting(_ keyword: String, from old: String?, to new: String?) {
      guard old != new else { return }
      if let old, !old.isEmpty { lines.append("-  \(keyword) \(old)") }
      if let new, !new.isEmpty { lines.append("+  \(keyword) \(new)") }
    }
    setting("HostName", from: library.hostName, to: file.hostName)
    setting("User", from: library.user, to: file.user)
    setting("Port", from: library.port == 22 ? nil : String(library.port), to: file.port == 22 ? nil : String(file.port))
    lines.append(contentsOf: keyLines(record: record, entry: entry))
    let had = record.profile.unsupported ?? []
    for token in had.sorted() where !limits.contains(token) {
      lines.append("-  \(Self.shownKeyword(token))")
    }
    for token in limits where !had.contains(token) {
      lines.append("+  \(Self.shownKeyword(token))")
    }
    return lines.contains { $0.hasPrefix("+") || $0.hasPrefix("-") } ? lines.joined(separator: "\n") : nil
  }

  /// A host the library does not have, or one it deleted and this file still names.
  private func added(_ entry: SSHConfig.Entry, limits: [String]) -> String {
    let face = HostFace(entry, defaultUser: defaultUserName())
    var lines = ["+Host \(entry.alias)"]
    if face.hostName != entry.alias { lines.append("+  HostName \(face.hostName)") }
    if !face.user.isEmpty { lines.append("+  User \(face.user)") }
    if face.port != 22 { lines.append("+  Port \(face.port)") }
    if let path = entry.identityFile { lines.append("+  IdentityFile \(Self.abbreviate(path))") }
    for token in limits { lines.append("+  \(Self.shownKeyword(token))") }
    return lines.joined(separator: "\n")
  }

  /// IdentityFile lines. A key kept in the keychain is not the file's to change.
  /// `default` is ssh's own key files: what a stanza with no IdentityFile means.
  private func keyLines(record: SharedHostRecord, entry: SSHConfig.Entry) -> [String] {
    let binding = snapshot.bindings[record.profile.authentication.primary.id]
    guard binding?.secretID == nil else { return [] }
    let old = binding?.keyPath.map(Self.abbreviate)
    let new = entry.identityFile.map(Self.abbreviate)
    if old == new {
      return new == nil && binding?.defaultKeys != true ? ["+  IdentityFile default"] : []
    }
    var lines: [String] = []
    if let old { lines.append("-  IdentityFile \(old)") }
    else if binding?.defaultKeys == true { lines.append("-  IdentityFile default") }
    if let new { lines.append("+  IdentityFile \(new)") }
    else { lines.append("+  IdentityFile default") }
    return lines
  }

  /// `~/.ssh/config` rather than the home directory spelled out.
  static func abbreviate(_ path: String) -> String {
    if path == "~" || path.hasPrefix("~/") { return path }
    let home = NSHomeDirectory()
    if path == home { return "~" }
    let prefix = home.hasSuffix("/") ? home : home + "/"
    guard path.hasPrefix(prefix) else { return path }
    return "~/" + path.dropFirst(prefix.count)
  }

  private static func shownKeyword(_ token: String) -> String {
    switch token {
    case "proxyjump": "ProxyJump"
    case "proxycommand": "ProxyCommand"
    case "hostkeyalias": "HostKeyAlias"
    case "canonicalizehostname": "CanonicalizeHostname"
    case "remotecommand": "RemoteCommand"
    case "sessiontype": "SessionType"
    case "match": "Match"
    default: token
    }
  }

  private struct Match {
    var id: UUID
    var replacing: String?
    var deleted: Bool
    var record: SharedHostRecord
  }

  /// The library host this stanza already is: the link, a rename in the same
  /// file, or the same name.
  private func match(for entry: SSHConfig.Entry) -> Match? {
    if let link = links[entry.alias], let record = snapshot.records[link.id] {
      return Match(id: link.id, replacing: nil, deleted: record.deleted, record: record)
    }
    let face = HostFace(entry, defaultUser: defaultUserName())
    let file = entry.file ?? location.path
    if let (alias, link) = links.first(where: { alias, link in
      guard alias != entry.alias, link.file == file,
        let record = snapshot.records[link.id], !record.deleted
      else { return false }
      return HostFace(record.profile).sameAddress(as: face)
    }), let record = snapshot.records[link.id] {
      return Match(id: link.id, replacing: alias, deleted: false, record: record)
    }
    let labeled = snapshot.records.values
      .filter { $0.profile.label == entry.alias }
      .sorted { $0.profile.id.uuidString < $1.profile.id.uuidString }
    guard let record = labeled.first(where: { !$0.deleted }) ?? labeled.first else { return nil }
    return Match(id: record.profile.id, replacing: nil, deleted: record.deleted, record: record)
  }

  /// Whether copying `entry` over `record` would change what the library says.
  private func differs(_ entry: SSHConfig.Entry, _ record: SharedHostRecord) -> Bool {
    let face = HostFace(entry, defaultUser: defaultUserName())
    if HostFace(record.profile) != face || record.profile.unsupported != unsupported(entry) { return true }
    let binding = snapshot.bindings[record.profile.authentication.primary.id]
    // A key kept in the keychain is not something the file names. Leave it.
    if binding?.secretID != nil { return false }
    if let path = entry.identityFile { return binding?.keyPath != path }
    return binding?.defaultKeys != true || binding?.keyPath != nil
  }

  private func apply(_ steps: [ConfigImport.Step]) throws {
    // Passwords are copied out of the keychain before the library changes,
    // so a keychain that refuses cannot leave a host pointing at nothing.
    var added: [String: (profile: HostProfile, password: UUID?)] = [:]
    for case .add(let entry) in steps {
      let profile = importedProfile(for: entry)
      added[entry.alias] = (profile, try carryPassword(of: entry, to: profile.id))
    }
    let defaultUser = defaultUserName()
    let modified = Self.modificationDates(of: config.files)

    try update(skippingUnchanged: true) { state in
      var links = state.imports ?? self.links
      func link(_ entry: SSHConfig.Entry, _ id: UUID) {
        links[entry.alias] = ImportLink(id: id, file: entry.file ?? location.path,
          seen: HostFace(entry, defaultUser: defaultUser))
      }
      func when(_ entry: SSHConfig.Entry) -> Date { entry.file.flatMap { modified[$0] } ?? Date() }

      for step in steps {
        switch step {
        case .add(let entry):
          guard let addedHost = added[entry.alias] else { continue }
          var profile = addedHost.0
          let password = addedHost.1
          profile.modified = when(entry)
          profile.unsupported = unsupported(entry)
          guard (try? profile.validate()) != nil else { continue }
          state.records[profile.id] = SharedHostRecord(profile: profile)
          // This Mac's own configuration vouches for what it says.
          state.approvals[profile.id] = profile.securityDigest
          if let password { state.passwordBindings[profile.id] = password }
          Self.bindKey(of: entry, to: profile, in: &state)
          link(entry, profile.id)

        case .take(let entry, let id, let replacing):
          guard var record = state.records[id] else { continue }
          if let replacing { links.removeValue(forKey: replacing) }
          record.profile.label = entry.alias
          record.profile.hostname = entry.hostName
          record.profile.username = entry.user ?? defaultUser
          record.profile.port = entry.port ?? 22
          record.profile.unsupported = unsupported(entry)
          record.profile.modified = when(entry)
          guard (try? record.profile.validate()) != nil else { continue }
          record.dirty = true
          state.records[id] = record
          state.approvals[id] = record.profile.securityDigest
          Self.bindKey(of: entry, to: record.profile, in: &state)
          link(entry, id)

        case .keep(let entry, let id):
          guard let record = state.records[id] else { continue }
          Self.bindKey(of: entry, to: record.profile, in: &state)
          link(entry, id)

        case .forget(let alias):
          links.removeValue(forKey: alias)
        }
      }
      state.imports = links
      state.adoptedAliases = [:]
    }
  }

  /// What of an entry's configuration Tether cannot follow.
  private func unsupported(_ entry: SSHConfig.Entry) -> [String]? {
    let limitations = config.importLimitations(alias: entry.alias)
    return limitations.isEmpty ? nil : limitations
  }

  /// This Mac's key for a host, as its configuration names it — unless a key
  /// was chosen in Tether, which the configuration has no say over.
  private static func bindKey(of entry: SSHConfig.Entry, to profile: HostProfile, in state: inout IdentitySnapshot) {
    let credential = profile.authentication.primary.id
    if state.bindings[credential]?.secretID != nil { return }
    state.bindings[credential] = entry.identityFile.map { LocalCredentialBinding(credentialID: credential, keyPath: $0) }
      ?? LocalCredentialBinding(credentialID: credential, defaultKeys: true)
  }

  static func modificationDates(of files: Set<String>) -> [String: Date] {
    var dates: [String: Date] = [:]
    for file in files {
      dates[file] = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate]) as? Date
    }
    return dates
  }
}
