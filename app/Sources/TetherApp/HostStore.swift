import CryptoKit
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
import Tether

/// A host someone saved.
///
/// `label` is separate from `hostname` because the two answer different
/// questions: one is what a person calls the machine, the other is how to
/// reach it. Collapsing them is why some clients show a list of IP addresses.
/// In `~/.ssh/config` the two are the stanza's name and its `HostName`, which
/// is the same distinction drawn by the people who invented the file.
struct Host: Identifiable, Hashable {
  var id = UUID()
  var label: String
  var hostname: String
  var port: UInt16
  var username: String
  /// Whether this host's password is kept in the keychain.
  ///
  /// The flag, not the password: what is stored lives in `SecretStore`, and
  /// this file holds nothing a person would mind being read (spec §18).
  var remembersPassword = false

  /// Where the private key lives, when this host uses one.
  ///
  /// A path, not the key: the file stays where the person put it, with the
  /// permissions they gave it, and Tether reads it at the moment of
  /// connecting rather than keeping a copy (spec §18).
  var keyPath: String?
  var profile: HostProfile?
  var credentialSecretID: UUID?
  var otpSecretID: UUID?
  var passwordSecretID: UUID?
  var passwordID: UUID { passwordSecretID ?? id }
  var connectionProblem: String?
  var accountScope: String = "local"
  var configurationVersion: String?

  var isManaged: Bool { profile != nil }
  var allowsMasterReuse: Bool { !isManaged }
  var allowsConnectionReuse: Bool {
    connectionProblem == nil && profile?.authentication.confirmation != .confirmConnection
  }

  /// An open session stays only while the security decision is the same one.
  ///
  /// A renamed label is still that host. A changed endpoint, route, policy,
  /// or a review that appeared after the session opened is not.
  func sameSessionTarget(as previous: Host) -> Bool {
    id == previous.id && accountScope == previous.accountScope
      && profile?.securityDigest == previous.profile?.securityDigest
      && connectionProblem == previous.connectionProblem
  }

  /// An `IdentityFile` in the ssh config is already a credential, so a
  /// password is not required to start the handshake. `ssh host` would not
  /// ask for one either.
  var offersConfiguredKey: Bool {
    if credentialSecretID != nil, profile?.authentication.primary.purpose != .password { return true }
    guard let keyPath else { return false }
    return !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The name `ssh` takes: the stanza's name, which is how a ControlPath is
  /// keyed. The resolved hostname would miss the master sitting on `Arrhenius`.
  var sshTarget: String {
    let name = label.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? hostname : name
  }

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

extension Host {
  /// The machine the app is running on.
  ///
  /// A host, not a category of its own. It opens into the same session type,
  /// draws through the same view and closes the same way; the only thing that
  /// differs is what is on the other end of the bytes, which is exactly the
  /// distinction the SDK's producer boundary exists to absorb.
  ///
  /// A fixed identifier rather than a hostname match, because `localhost` is
  /// also a perfectly ordinary thing to *reach over SSH* — someone forwarding
  /// a port to a container types it every day, and guessing from the name
  /// would take their connection away from them.
  static let localID = UUID(uuidString: "10CA1005-0000-4000-A000-000000000001")!

  static var local: Host {
    Host(
      id: localID,
      label: "localhost",
      hostname: "localhost",
      port: 22,
      username: defaultUserName(),
      keyPath: nil)
  }

  var isLocal: Bool { id == Host.localID }
}

extension Host {
  /// The identity of the host a stanza names.
  ///
  /// Derived from the name rather than invented, because the store is a file
  /// the app does not own: there is nowhere in `~/.ssh/config` to keep a
  /// generated identifier, and inventing one per read would hand the keychain
  /// a different host every launch. The name is what identifies a host in
  /// that file, so it is what identifies one here.
  ///
  /// A hash rather than the name itself, so that what ends up in a keychain
  /// item and a window's state is a fixed-width value with no punctuation in
  /// it, and so the type stays a `UUID` for everything that already holds one.
  static func id(forAlias alias: String) -> UUID {
    var digest = Array(SHA256.hash(data: Data(("ssh-config:" + alias).utf8)).prefix(16))
    // Marked as a name-based UUID rather than a random one, which is what it
    // is. Version 5 in the high nibble of byte 6, variant in byte 8.
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80
    return UUID(uuid: (
      digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
      digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
    ))
  }
}

/// Shared host configuration and device-local SSH imports. Only managed profiles sync.
@MainActor
@Observable
final class HostStore {
  private(set) var hosts: [Host] = []
  var search = ""
  private(set) var problem: String?
  private(set) var syncStatus = "Saved on this device"
  private(set) var scope = "local"
  private(set) var accountGeneration = 0
  private(set) var snapshot = IdentitySnapshot()
  private var database: IdentityDatabase?
  private let location: URL
  private let secrets: any SecretStore
  private var config = SSHConfig("")
  private var unreadable = false
  private var cloud: HostCloudSync?
  private(set) var continuity: ContinuityService?
  private let allowCloud: Bool

  var listed: [Host] { TerminalSession.isLocalAvailable ? [.local] + hosts : hosts }
  var filtered: [Host] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    return query.isEmpty ? listed : listed.filter {
      $0.label.lowercased().contains(query) || $0.hostname.lowercased().contains(query)
        || $0.username.lowercased().contains(query)
    }
  }
  static var sshConfig: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh/config")
  }
  var locationDescription: String { "Tether Library" }
  static var databaseLocation: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Tether/identity.sqlite")
  }

  init(location override: URL? = nil, secrets: any SecretStore = Keychain(), databaseURL: URL? = nil) {
    self.secrets = secrets
    location = override ?? Self.sshConfig
    allowCloud = override == nil && databaseURL == nil
    do {
      let database = try IdentityDatabase(location: databaseURL ?? override?.appendingPathExtension("sqlite") ?? Self.databaseLocation)
      self.database = database
      // The last known account's offline library stays available until CloudKit
      // reports a sign-out or switch. Never move it into another account.
      scope = try database.read(String.self, scope: "active-account") ?? "local"
      snapshot = try database.read(IdentitySnapshot.self, scope: scope) ?? IdentitySnapshot()
    } catch { problem = error.localizedDescription }
    reload()
  }

  func startSync() async {
    guard allowCloud, database != nil else { return }
    if cloud == nil { cloud = HostCloudSync(store: self) }
    await cloud?.start()
    if continuity == nil { continuity = ContinuityService(store: self, database: cloud?.continuityDatabase) }
    else { continuity?.useDatabase(cloud?.continuityDatabase) }
  }
  func syncNow() async { await cloud?.synchronize() }
  func setSyncStatus(_ text: String) { syncStatus = text }

  func switchAccount(_ account: String) throws {
    guard account != scope else { return }
    guard let database else { throw IdentityError.storage("Identity database unavailable.") }
    let next = try database.read(IdentitySnapshot.self, scope: account) ?? IdentitySnapshot()
    try database.write(account, scope: "active-account")
    continuity?.stop()
    continuity = nil
    scope = account
    snapshot = next
    accountGeneration += 1
    reload()
  }

  func update(_ change: (inout IdentitySnapshot) throws -> Void) throws {
    guard let database else { throw IdentityError.storage("Identity database unavailable.") }
    var next = snapshot
    try change(&next)
    try database.write(next, scope: scope)
    snapshot = next
    reload()
  }

  func reload() {
    if FileManager.default.fileExists(atPath: location.path) {
      do {
        config = SSHConfig(try String(contentsOf: location, encoding: .utf8))
        unreadable = false
      } catch {
        unreadable = true
        problem = "Could not read SSH configuration: \(error.localizedDescription)"
      }
    } else { config = SSHConfig(""); unreadable = false }
    let remembered = Set((try? secrets.saved())?.map(\.id) ?? [])
    var result: [Host] = []
    for record in snapshot.records.values where !record.deleted {
      let p = record.profile
      let primary = snapshot.bindings[p.authentication.primary.id]
      let otp = p.authentication.otp.flatMap { snapshot.bindings[$0.id] }
      var issue: String?
      if !record.conflicts.isEmpty { issue = "Resolve configuration conflict" }
      else if snapshot.approvals[p.id] != p.securityDigest { issue = "Review authentication settings" }
      else if !p.jumpHosts.isEmpty { issue = IdentityError.unsupportedRoute.localizedDescription }
      else if p.authentication.primary.purpose == .ssh && primary == nil { issue = IdentityError.missingCredential.localizedDescription }
      else if p.authentication.otp != nil && otp == nil && p.authentication.remoteApprovalDevice == nil {
        issue = "Set up MFA on this device"
      }
      result.append(Host(id: p.id, label: p.label, hostname: p.hostname, port: p.port,
        username: p.username, remembersPassword: snapshot.passwordBindings[p.id].map(remembered.contains) ?? false, keyPath: primary?.keyPath,
        profile: p, credentialSecretID: primary?.secretID, otpSecretID: otp?.secretID,
        passwordSecretID: snapshot.passwordBindings[p.id], connectionProblem: issue, accountScope: scope, configurationVersion: p.versionDigest))
    }
    for e in config.entries where snapshot.adoptedAliases[e.alias] == nil {
      let id = Host.id(forAlias: e.alias)
      result.append(Host(id: id, label: e.alias, hostname: e.hostName, port: e.port ?? 22,
        username: e.user ?? defaultUserName(), remembersPassword: remembered.contains(id), keyPath: e.identityFile))
    }
    hosts = result.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
  }

  @discardableResult
  func save(_ host: Host, password: String? = nil) -> Bool {
    guard !host.isLocal else { return false }
    do {
      var p: HostProfile
      if let existing = host.profile {
        guard host.accountScope == scope,
          host.configurationVersion == snapshot.records[host.id]?.profile.versionDigest else {
          throw IdentityError.storage("This host changed while it was open. Reopen its settings before saving.")
        }
        p = existing
      } else {
        // Existing OpenSSH entries stay user-owned until explicit adoption.
        if config.entries.contains(where: { Host.id(forAlias: $0.alias) == host.id }) {
          throw IdentityError.storage("Add this host to Tether before editing it here.")
        }
        let identity = AccountIdentity(name: host.label.isEmpty ? host.hostname : host.label)
        let credential = CredentialDescriptor(identityID: identity.id, purpose: host.offersConfiguredKey ? .ssh : .password)
        p = HostProfile(id: host.id, label: host.label, hostname: host.hostname, port: host.port,
          username: host.username, authentication: AuthenticationProfile(identity: identity, primary: credential))
      }
      p.label = host.label.isEmpty ? host.hostname : host.label
      p.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
      p.username = host.username.trimmingCharacters(in: .whitespaces)
      p.port = host.port
      if host.offersConfiguredKey { p.authentication.primary.purpose = .ssh }
      try p.validate()
      // A rejected Keychain write must not make the UI report a successful save.
      let passwordID = snapshot.passwordBindings[p.id] ?? UUID()
      if let password {
        if password.isEmpty { try secrets.forget(passwordID) }
        else { var target = host; target.id = passwordID; try secrets.remember(password, for: target) }
      }
      try update { state in
        if let password { state.passwordBindings[p.id] = password.isEmpty ? nil : passwordID }
        var record = state.records[p.id] ?? SharedHostRecord(profile: p)
        guard !record.deleted else { throw IdentityError.storage("This host was deleted. Create a new host to restore it.") }
        guard record.conflicts.isEmpty else { throw IdentityError.needsReview }
        record.profile = p
        record.dirty = true
        state.records[p.id] = record
        if p.authentication.primary.purpose == .password {
          state.bindings.removeValue(forKey: p.authentication.primary.id)
        } else if let secretID = host.credentialSecretID {
          let previous = state.bindings[p.authentication.primary.id]
          state.bindings[p.authentication.primary.id] = LocalCredentialBinding(credentialID: p.authentication.primary.id,
            secretID: secretID, publicKey: previous?.secretID == secretID ? previous?.publicKey : nil)
        } else if let path = host.keyPath {
          state.bindings[p.authentication.primary.id] = LocalCredentialBinding(credentialID: p.authentication.primary.id, keyPath: path)
        }
        state.approvals[p.id] = p.securityDigest
      }
      problem = nil
      cloud?.enqueue()
      return true
    } catch { problem = error.localizedDescription; return false }
  }

  func adopt(_ host: Host) {
    guard !host.isLocal, !host.isManaged, !unreadable, snapshot.adoptedAliases[host.sshTarget] == nil else { return }
    do {
      let limitations = config.importLimitations(alias: host.sshTarget)
      guard limitations.isEmpty else { throw IdentityError.storage("Cannot import: " + limitations.joined(separator: ", ")) }
      let id = snapshot.adoptedAliases[host.sshTarget] ?? UUID()
      let identity = AccountIdentity(name: host.label)
      let credential = CredentialDescriptor(identityID: identity.id, purpose: host.offersConfiguredKey ? .ssh : .password)
      let p = HostProfile(id: id, label: host.label, hostname: host.hostname, port: host.port, username: host.username,
        authentication: AuthenticationProfile(identity: identity, primary: credential))
      try p.validate()
      // Copy first; retain the original credential until both durable references exist.
      let password = try secrets.password(for: host.id)
      let passwordID = UUID()
      if let password {
        var migrated = host; migrated.id = passwordID
        try secrets.remember(password, for: migrated)
      }
      try update { state in
        if password != nil { state.passwordBindings[id] = passwordID }
        guard state.adoptedAliases[host.sshTarget] == nil else { return }
        state.records[id] = SharedHostRecord(profile: p)
        state.adoptedAliases[host.sshTarget] = id
        state.approvals[id] = p.securityDigest
        if let path = host.keyPath {
          state.bindings[credential.id] = LocalCredentialBinding(credentialID: credential.id, keyPath: path)
        }
      }
      // The original user SSH entry is still usable and still owns its password.
      cloud?.enqueue()
      problem = nil
    } catch { problem = error.localizedDescription }
  }

  func delete(_ host: Host) {
    guard host.isManaged else { problem = "Manage this entry in your SSH configuration."; return }
    do {
      try update { state in
        guard var record = state.records[host.id] else { return }
        record.deleted = true; record.dirty = true; record.conflicts = [:]
        state.records[host.id] = record
        state.approvals.removeValue(forKey: host.id)
      }
      if let passwordID = snapshot.passwordBindings[host.id] { try secrets.forget(passwordID) }
      cloud?.enqueue()
      problem = nil
    } catch { problem = error.localizedDescription }
  }

  func approve(_ id: UUID) {
    do {
      try update { state in
        guard let record = state.records[id], !record.deleted, record.conflicts.isEmpty else { throw IdentityError.needsReview }
        try record.profile.validate()
        state.approvals[id] = record.profile.securityDigest
      }
      problem = nil
    } catch { problem = error.localizedDescription }
  }

  func resolve(_ id: UUID, useRemote: Bool) {
    do {
      try update { state in
        guard var record = state.records[id] else { return }
        try record.resolve(useRemote: useRemote)
        state.records[id] = record
        state.approvals.removeValue(forKey: id)
      }
      cloud?.enqueue()
    } catch { problem = error.localizedDescription }
  }

  func receive(_ profile: HostProfile, deleted: Bool, systemFields: Data?) throws {
    try update { state in
      if var existing = state.records[profile.id] {
        try existing.merge(profile, deleted: deleted, systemFields: systemFields)
        state.records[profile.id] = existing
      } else {
        try profile.validate()
        state.records[profile.id] = SharedHostRecord(profile: profile, base: profile, deleted: deleted,
          dirty: false, systemFields: systemFields)
      }
    }
  }

  func importLocalLibrary() {
    guard scope.hasPrefix("icloud:") else { return }
    do {
      guard let source = try database?.read(IdentitySnapshot.self, scope: "local") else { return }
      try update { state in
        for (id, record) in source.records where !record.deleted && state.records[id] == nil {
          var imported = record; imported.base = nil; imported.systemFields = nil; imported.dirty = true
          state.records[id] = imported
          state.approvals[id] = source.approvals[id]
          state.passwordBindings[id] = source.passwordBindings[id]
          for credential in [record.profile.authentication.primary.id, record.profile.authentication.otp?.id].compactMap({ $0 }) {
            state.bindings[credential] = source.bindings[credential]
          }
        }
        for (alias, id) in source.adoptedAliases where state.records[id] != nil { state.adoptedAliases[alias] = id }
      }
      scheduleSync()
    } catch { recordProblem(error) }
  }

  func scheduleSync() { cloud?.enqueue() }

  func recordProblem(_ error: Error) { problem = error.localizedDescription }
}
