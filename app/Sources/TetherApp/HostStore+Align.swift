import Foundation

/// The library written back to this Mac's SSH configuration, only when a
/// person agrees.
///
/// `reconcile` has already run, so a stanza someone edited is in the library.
/// What remains is the other way: the library says something the file does
/// not. Asking is the whole of the policy. Declining writes nothing, and the
/// same difference is not asked again until it changes or the app is opened
/// again.
extension HostStore {
  func alignment() -> ConfigAlign.Plan {
    ConfigAlign.plan(.init(
      entries: config.entries, records: snapshot.records, links: links,
      keyPaths: keyPaths, file: location.path, defaultUser: defaultUserName()))
  }

  /// Compares the file with the library and, on a Mac, asks when they differ.
  func reviewConfiguration() {
    #if os(macOS)
      guard !unreadable else { return }
      let plan = alignment()
      if plan.isEmpty {
        pendingAlignment = nil
        return
      }
      if plan == declinedAlignment || plan == pendingAlignment { return }
      pendingAlignment = plan
    #endif
  }

  func declineConfigurationAlignment() {
    declinedAlignment = pendingAlignment
    pendingAlignment = nil
  }

  /// Writes the answer they agreed to, then reads the file back. A write that
  /// would not resolve to the library is not performed.
  func writeConfigurationAlignment() {
    #if os(macOS)
      guard let plan = pendingAlignment, !plan.isEmpty else { return }
      do {
        let original = FileManager.default.fileExists(atPath: location.path)
          ? try String(contentsOf: location, encoding: .utf8) : ""
        let rewritten = try Self.aligned(original, to: plan, file: location)
        if rewritten != original { try Self.replaceSSHConfig(at: location, with: rewritten) }
        try retarget(plan)
        declinedAlignment = nil
        pendingAlignment = nil
        reload()
        reconcile()
      } catch {
        declinedAlignment = plan
        pendingAlignment = nil
        recordProblem(IdentityError.storage("Could not update SSH configuration."))
      }
    #endif
  }

  /// The text to put in `file`, or a throw when neither pass would make `ssh`
  /// resolve the library. Includes are followed, so a block is added when an
  /// in-place edit would lose to a file this one includes.
  private static func aligned(_ original: String, to plan: ConfigAlign.Plan, file: URL) throws -> String {
    let user = defaultUserName()
    let first = SSHConfigRewrite.applying(plan.edits, to: original, defaultUser: user)
    if ConfigAlign.resolves(plan, in: SSHConfig.parse(first, file: file), defaultUser: user) { return first }
    let covered = SSHConfigRewrite.applying(plan.edits, to: original, defaultUser: user, forceCover: true)
    guard ConfigAlign.resolves(plan, in: SSHConfig.parse(covered, file: file), defaultUser: user) else {
      throw IdentityError.storage("Could not update SSH configuration.")
    }
    return covered
  }

  /// A rename has to move the link before `reconcile` sees the file, or the
  /// old name looks deleted and the new name looks like a second host.
  private func retarget(_ plan: ConfigAlign.Plan) throws {
    let renames: [(String, HostFace)] = plan.edits.compactMap { edit in
      guard case .update(let face, let from?) = edit else { return nil }
      return (from, face)
    }
    guard !renames.isEmpty else { return }
    let path = location.path
    try update { state in
      var links = state.imports ?? self.links
      for (from, face) in renames {
        guard var link = links.removeValue(forKey: from) else { continue }
        link.seen = face
        link.file = path
        links[face.name] = link
      }
      state.imports = links
    }
  }

  private var keyPaths: [UUID: String] {
    var paths: [UUID: String] = [:]
    for record in snapshot.records.values where !record.deleted {
      let credential = record.profile.authentication.primary.id
      if let path = snapshot.bindings[credential]?.keyPath, !path.isEmpty {
        paths[record.profile.id] = path
      }
    }
    return paths
  }

  /// Replaces the file without replacing a symlink: the text lands on the
  /// file the link names. Mode is kept. A new file is readable only by its
  /// owner, which is what `ssh` requires of a configuration it will trust.
  static func replaceSSHConfig(at location: URL, with text: String) throws {
    let directory = location.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    let destination = location.resolvingSymlinksInPath()
    let mode = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int) ?? 0o600
    let temp = directory.appending(path: ".\(location.lastPathComponent).tether-\(UUID().uuidString)")
    do {
      try Data(text.utf8).write(to: temp)
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp, backupItemName: nil,
          options: .usingNewMetadataOnly)
      } else {
        try FileManager.default.moveItem(at: temp, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: temp)
      throw error
    }
  }
}
