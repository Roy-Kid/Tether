import Foundation

/// This Mac's SSH configuration, read into the library.
///
/// `ConfigImport` decides; this does it, in one write to the library.
/// Nothing under `~/.ssh` is ever written: the configuration is where hosts
/// come from on a Mac, and the library — shared with every device — is the
/// one place they are kept.
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
          guard var (profile, password) = added[entry.alias] else { continue }
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
