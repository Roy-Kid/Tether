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
struct Host: Identifiable, Hashable, Codable {
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

  /// The key file this device logs in with: an `IdentityFile` from
  /// `~/.ssh/config`, read where it lies at the moment of connecting.
  var keyPath: String?
  var profile: HostProfile?
  /// A key this device keeps in its own keychain instead — one picked in the
  /// editor, whose file may live somewhere this app can reach only once, or
  /// one generated here. Never both this and `keyPath`.
  var credentialSecretID: UUID?
  /// Log in with `ssh`'s default key files, as the ssh-config entry this
  /// host was added from did.
  var usesDefaultKeys = false
  /// How this device logged in to the host when it was read, so a save from
  /// a sheet opened earlier cannot undo a key made since.
  var credentialBinding: LocalCredentialBinding?
  var otpSecretID: UUID?
  var passwordSecretID: UUID?
  var passwordID: UUID { passwordSecretID ?? id }
  var connectionProblem: String?
  var accountScope: String = "local"
  var configurationVersion: String?

  var isManaged: Bool { profile != nil }

  /// Whether a connection the person's own `ssh` already holds may carry
  /// this session. Only on a Mac, and only for a host whose settings ask for
  /// nothing that path would skip: a confirmation, a one-time code, an
  /// approval from another device.
  var allowsMasterReuse: Bool {
    #if os(macOS)
      guard connectionProblem == nil else { return false }
      guard let authentication = profile?.authentication else { return true }
      return authentication.confirmation == .automatic && authentication.otp == nil
        && authentication.remoteApprovalDevice == nil
    #else
      false
    #endif
  }

  /// A setting this host's SSH configuration has that Tether cannot follow,
  /// said so. Only `ssh` itself can reach such a host, through a connection
  /// it already holds.
  var routeProblem: String? {
    guard let unsupported = profile?.unsupported, !unsupported.isEmpty else { return nil }
    return "Uses \(unsupported.joined(separator: ", ")), which Tether cannot follow yet."
  }
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

  /// A key on this device is already a credential, so a password is not
  /// required to start the handshake. `ssh host` would not ask for one either.
  var offersConfiguredKey: Bool {
    if credentialSecretID != nil { return true }
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
    nameBasedUUID("ssh-config:" + alias)
  }
}

/// The hosts: one library — the one source of truth — synchronized through
/// iCloud, and on a Mac fed by `~/.ssh/config` (`HostStore+Import`). The file
/// is written back only when a person agrees (`HostStore+Align`). There is one
/// kind of host. A host that arrives from
/// another device on the same Apple ID is already trusted. Private keys
/// travel with the library; passwords stay on the device that saved them.
@MainActor
@Observable
final class HostStore {
  private(set) var hosts: [Host] = []
  var search = ""
  private(set) var problem: String?
  private(set) var syncStatus = "Saved on this device"
  /// Why the last attempt to synchronize could not, when it could not.
  private(set) var syncFailure: String?
  private(set) var lastSynced: Date?
  /// A sync the person asked for is running.
  private(set) var syncing = false
  private(set) var scope = "local"
  private(set) var accountGeneration = 0
  private(set) var snapshot = IdentitySnapshot()
  private var database: IdentityDatabase?
  /// This Mac's `~/.ssh/config`, or the file a test gave instead.
  let location: URL
  private let secrets: any SecretStore
  let credentials: DeviceCredentialStore
  private(set) var config = SSHConfig("")
  private(set) var unreadable = false
  /// A difference between the library and `~/.ssh/config` waiting on an
  /// answer. Nothing is written until they give one.
  var pendingAlignment: ConfigAlign.Plan?
  /// The difference they declined. Not asked again until it changes.
  var declinedAlignment: ConfigAlign.Plan?
  /// Hosts an import from `~/.ssh/config` would overwrite, waiting on an
  /// answer. The file is never written.
  var pendingImport: ConfigurationImport?
  /// The diff they declined this launch. Not asked again until the
  /// difference changes, or the app is opened again.
  var declinedImport: String?
  private var cloud: HostCloudSync?
  private(set) var keyBindings: KeyBindingStore?
  private(set) var continuity: ContinuityService?
  private let allowCloud: Bool
  private var swept = false

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

  init(location override: URL? = nil, secrets: any SecretStore = Keychain(),
    credentials: DeviceCredentialStore = DeviceCredentialStore(), databaseURL: URL? = nil) {
    self.secrets = secrets
    self.credentials = credentials
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
    trustArrivedSettings()
  }

  func startSync() async {
    guard allowCloud, database != nil else { return }
    if cloud == nil { cloud = HostCloudSync(store: self) }
    await cloud?.start()
    if continuity == nil { continuity = ContinuityService(store: self, database: cloud?.continuityDatabase) }
    else { continuity?.useDatabase(cloud?.continuityDatabase) }
  }

  func useKeyBindings(_ bindings: KeyBindingStore) {
    keyBindings = bindings
    bindings.switchAccount(scope)
    bindings.onChange = { [weak self] in self?.cloud?.enqueue() }
  }
  func syncNow() async { await cloud?.synchronize() }

  /// `failure` is what went wrong, for a person who asked to sync.
  func setSyncStatus(_ text: String, failure: String? = nil) {
    syncLog.info("\(text, privacy: .public) \(failure ?? "", privacy: .public)")
    syncStatus = text
    syncFailure = failure
  }

  func didSync() {
    lastSynced = Date()
    syncFailure = nil
  }

  /// The sync button reads the whole library through iCloud again.
  /// `~/.ssh/config` is a separate import, and only when they ask.
  func syncEverything() async {
    guard !syncing else { return }
    syncing = true
    defer { syncing = false }
    if cloud == nil { await startSync() } else { await cloud?.resynchronize() }
  }

  func switchAccount(_ account: String) throws {
    guard account != scope else { return }
    guard let database else { throw IdentityError.storage("Identity database unavailable.") }
    let next = try database.read(IdentitySnapshot.self, scope: account) ?? IdentitySnapshot()
    try database.write(account, scope: "active-account")
    continuity?.stop()
    continuity = nil
    scope = account
    snapshot = next
    keyBindings?.switchAccount(account)
    accountGeneration += 1
    reload()
  }

  /// Every change to the library goes through here, and so does letting go
  /// of what a change leaves behind: a key or password nothing points at any
  /// more is removed from the keychain once the library no longer needs it —
  /// never before, so a failed write cannot leave a host without its key.
  func update(skippingUnchanged: Bool = false, _ change: (inout IdentitySnapshot) throws -> Void) throws {
    guard let database else { throw IdentityError.storage("Identity database unavailable.") }
    var next = snapshot
    try change(&next)
    next.prune()
    if skippingUnchanged {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      if try encoder.encode(next) == encoder.encode(snapshot) { return }
    }
    try database.write(next, scope: scope)
    var released = snapshot.credentialSecrets.subtracting(next.credentialSecrets)
    var forgotten = snapshot.passwordSecrets.subtracting(next.passwordSecrets)
    snapshot = next
    if !released.isEmpty || !forgotten.isEmpty {
      // Another account's library may point at the same item — a copy made
      // before libraries moved rather than copied. Unsure means keep it.
      if let others = try? otherLibraries() {
        for library in others {
          released.subtract(library.credentialSecrets)
          forgotten.subtract(library.passwordSecrets)
        }
      } else {
        released = []
        forgotten = []
      }
    }
    release(credentials: released, passwords: forgotten)
    reload()
  }

  /// Every library but the active one.
  private func otherLibraries() throws -> [IdentitySnapshot] {
    guard let database else { return [] }
    return try database.scopes().filter { $0 != "active-account" && $0 != scope }.compactMap {
      try database.read(IdentitySnapshot.self, scope: $0)
    }
  }

  private func release(credentials released: Set<UUID>, passwords forgotten: Set<UUID>) {
    // Each on its own: one item the keychain refuses to delete is no reason
    // to keep the others.
    for (id, store) in released.map({ ($0, credentials.secrets) }) + forgotten.map({ ($0, secrets) }) {
      do { try store.forget(id) } catch { problem = error.localizedDescription }
    }
  }

  /// Keychain items no library points at, left by earlier versions that let
  /// go of a host without letting go of its key. Once per launch, before any
  /// editor could be holding a key it has not saved yet, and only when every
  /// library could be read — one that could not might be the one using it.
  func sweepCredentials() {
    // A store opened on another file sees only its own libraries, and would
    // take the real ones' keys for strays.
    guard allowCloud, !swept, let database else { return }
    swept = true
    do {
      var referenced: Set<UUID> = []
      for scope in try database.scopes() where scope != "active-account" {
        guard let library = try database.read(IdentitySnapshot.self, scope: scope) else { continue }
        referenced.formUnion(library.credentialSecrets)
      }
      for item in try credentials.saved() where !referenced.contains(item.id) {
        try credentials.forget(item.id)
      }
    } catch { problem = error.localizedDescription }
  }

  func reload() {
    if FileManager.default.fileExists(atPath: location.path) {
      do {
        config = try SSHConfig.read(location)
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
      else if !p.jumpHosts.isEmpty { issue = IdentityError.unsupportedRoute.localizedDescription }
      // No key or code seed on this device is not a problem to block on: the
      // login asks the person for what this device cannot answer itself.
      result.append(Host(id: p.id, label: p.label, hostname: p.hostname, port: p.port,
        username: p.username, remembersPassword: snapshot.passwordBindings[p.id].map(remembered.contains) ?? false, keyPath: primary?.keyPath,
        profile: p, credentialSecretID: primary?.secretID, usesDefaultKeys: primary?.defaultKeys == true,
        credentialBinding: primary, otpSecretID: otp?.secretID,
        passwordSecretID: snapshot.passwordBindings[p.id], connectionProblem: issue, accountScope: scope,
        configurationVersion: p.versionDigest))
    }
    hosts = result.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
  }

  /// The password an ssh-config entry had saved, copied to be the host's
  /// too when the host has none yet. Copied, not moved: the entry is still
  /// the person's, and still usable on its own.
  func carryPassword(of entry: SSHConfig.Entry, to id: UUID) throws -> UUID? {
    guard snapshot.passwordBindings[id] == nil,
      let password = try secrets.password(for: Host.id(forAlias: entry.alias)) else { return nil }
    let copy = UUID()
    try secrets.remember(password, for: Host(id: copy, label: entry.alias, hostname: entry.hostName,
      port: entry.port ?? 22, username: entry.user ?? defaultUserName()))
    return copy
  }

  @discardableResult
  func save(_ host: Host, password: String? = nil) -> Bool {
    guard !host.isLocal else { return false }
    do {
      var p: HostProfile
      if let existing = host.profile {
        guard host.accountScope == scope,
          host.configurationVersion == snapshot.records[host.id]?.profile.versionDigest,
          // A key made or chosen elsewhere since this copy was read is not
          // this save's to undo.
          host.credentialBinding == snapshot.bindings[existing.authentication.primary.id] else {
          throw IdentityError.storage("This host changed while it was open. Reopen its settings before saving.")
        }
        p = existing
      } else {
        p = Self.newProfile(id: host.id, label: host.label.isEmpty ? host.hostname : host.label,
          hostname: host.hostname, username: host.username, port: host.port, key: host.offersConfiguredKey)
      }
      p.label = host.label.isEmpty ? host.hostname : host.label
      p.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
      p.username = host.username.trimmingCharacters(in: .whitespaces)
      p.port = host.port
      if p != host.profile { p.modified = Date() }
      try p.validate()
      // A rejected Keychain write must not make the UI report a successful save.
      let passwordID = snapshot.passwordBindings[p.id] ?? UUID()
      if let password, !password.isEmpty {
        var target = host; target.id = passwordID; try secrets.remember(password, for: target)
      }
      let profile = p
      try update { state in
        if let password { state.passwordBindings[profile.id] = password.isEmpty ? nil : passwordID }
        var record = state.records[profile.id] ?? SharedHostRecord(profile: profile)
        guard !record.deleted else { throw IdentityError.storage("This host was deleted. Create a new host to restore it.") }
        guard record.conflicts.isEmpty else { throw IdentityError.needsReview }
        if record.profile != profile || state.records[profile.id] == nil {
          record.profile = profile
          record.dirty = true
        }
        let credential = profile.authentication.primary.id
        let previous = state.bindings[credential]
        let binding = Self.binding(for: host, credential: credential, previous: previous)
        state.bindings[credential] = binding
        if Self.keyChoiceChanged(from: previous, to: binding) {
          // The key is shared with the other devices on this Apple ID. The
          // profile — where the host is, and how it authenticates — is not
          // what changed.
          record.dirty = true
          record.syncedKeyDigest = nil
          record.forgetSharedKey = Self.hasKey(binding) ? nil : true
        }
        state.records[profile.id] = record
        state.approvals[profile.id] = profile.securityDigest
      }
      problem = nil
      reconcile()
      cloud?.enqueue()
      return true
    } catch { problem = error.localizedDescription; return false }
  }

  /// How this device logs in to a host: a key in its keychain, a key file,
  /// or — with neither — whatever the server asks for.
  private static func binding(for host: Host, credential: UUID, previous: LocalCredentialBinding?) -> LocalCredentialBinding? {
    if let secretID = host.credentialSecretID {
      return LocalCredentialBinding(credentialID: credential, secretID: secretID,
        publicKey: previous?.secretID == secretID ? previous?.publicKey : nil)
    }
    if let path = host.keyPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return LocalCredentialBinding(credentialID: credential, keyPath: path)
    }
    if host.usesDefaultKeys { return LocalCredentialBinding(credentialID: credential, defaultKeys: true) }
    return nil
  }

  /// A host as Tether starts one: how `ssh` would treat it — no extra
  /// confirmation, no second factor — until someone says otherwise.
  nonisolated static func newProfile(id: UUID, label: String, hostname: String, username: String, port: UInt16,
    key: Bool) -> HostProfile {
    let identity = AccountIdentity(name: label)
    let credential = CredentialDescriptor(identityID: identity.id, purpose: key ? .ssh : .password)
    var authentication = AuthenticationProfile(identity: identity, primary: credential)
    authentication.confirmation = .automatic
    var profile = HostProfile(id: id, label: label, hostname: hostname, port: port, username: username,
      authentication: authentication)
    profile.modified = Date()
    return profile
  }

  /// A host as an SSH configuration names it. Every identifier comes from
  /// its name, so two Macs adding the same stanza before they have
  /// synchronized add the same host, not two that then have to be told
  /// apart — unless that name belonged to a host someone deleted, whose
  /// tombstone a new stanza must not be mistaken for.
  func importedProfile(for entry: SSHConfig.Entry) -> HostProfile {
    let named = nameBasedUUID("host:" + entry.alias)
    let id = snapshot.records[named] == nil ? named : UUID()
    let identity = AccountIdentity(id: nameBasedUUID("identity:" + id.uuidString), name: entry.alias)
    let credential = CredentialDescriptor(id: nameBasedUUID("credential:" + id.uuidString), identityID: identity.id,
      purpose: .ssh)
    var authentication = AuthenticationProfile(id: nameBasedUUID("authentication:" + id.uuidString),
      identity: identity, primary: credential)
    authentication.confirmation = .automatic
    return HostProfile(id: id, label: entry.alias, hostname: entry.hostName, port: entry.port ?? 22,
      username: entry.user ?? defaultUserName(), authentication: authentication)
  }

  /// Its key, code seed and password go with it: `update` lets go of
  /// whatever the deleted host was the last thing pointing at.
  func delete(_ host: Host) {
    guard host.isManaged else { return }
    do {
      try update { state in
        guard var record = state.records[host.id] else { return }
        record.deleted = true; record.dirty = true; record.conflicts = [:]
        state.records[host.id] = record
      }
      reconcile()
      cloud?.enqueue()
      problem = nil
    } catch { problem = error.localizedDescription }
  }

  func resolve(_ id: UUID, useRemote: Bool) {
    do {
      try update { state in
        guard var record = state.records[id] else { return }
        let before = record.profile
        try record.resolve(useRemote: useRemote)
        state.records[id] = record
        Self.rebind(from: before, to: record.profile, in: &state)
        Self.trust(id, in: &state)
      }
      cloud?.enqueue()
    } catch { problem = error.localizedDescription }
  }

  func receive(_ profile: HostProfile, deleted: Bool, systemFields: Data?, privateKey: String? = nil) throws {
    try update { state in
      if var existing = state.records[profile.id] {
        let before = existing.profile
        try existing.merge(profile, deleted: deleted, systemFields: systemFields)
        state.records[profile.id] = existing
        Self.rebind(from: before, to: existing.profile, in: &state)
      } else {
        try profile.validate()
        state.records[profile.id] = SharedHostRecord(profile: profile, base: profile, deleted: deleted,
          dirty: false, systemFields: systemFields)
      }
      // The private database is this Apple ID. A host that arrived through
      // it is this person's host; nothing further is asked before connecting.
      Self.trust(profile.id, in: &state)
      if !deleted { try self.take(privateKey, for: profile.id, in: &state) }
    }
  }

  /// Hosts already in the library when review went away. The same trust
  /// `receive` gives a host that arrives now.
  private func trustArrivedSettings() {
    let stale = snapshot.records.contains { id, record in
      !record.deleted && record.conflicts.isEmpty && snapshot.approvals[id] != record.profile.securityDigest
    }
    guard stale else { return }
    try? update { state in
      for id in state.records.keys { Self.trust(id, in: &state) }
    }
  }

  private static func trust(_ id: UUID, in state: inout IdentitySnapshot) {
    guard let record = state.records[id], !record.deleted, record.conflicts.isEmpty else { return }
    state.approvals[id] = record.profile.securityDigest
  }

  /// Hosts kept while no iCloud account was signed in join the account that
  /// signs in, instead of vanishing behind it. Moved, not copied: a library
  /// left behind would be handed to the next account to sign in as well.
  /// Called when an account becomes active; the keychain items stay where
  /// they are, now pointed at by the account's library.
  /// Settings from another device can name this host's credentials by other
  /// identifiers than the ones this device bound its key and code seed to.
  /// The secret is the same one, so it follows the setting rather than being
  /// let go of.
  private static func rebind(from old: HostProfile, to new: HostProfile, in state: inout IdentitySnapshot) {
    let pairs: [(UUID?, UUID?)] = [
      (old.authentication.primary.id, new.authentication.primary.id),
      (old.authentication.otp?.id, new.authentication.otp?.id),
    ]
    for case let (from?, to?) in pairs where from != to && state.bindings[to] == nil {
      guard var binding = state.bindings.removeValue(forKey: from) else { continue }
      binding.credentialID = to
      state.bindings[to] = binding
    }
  }

  /// Hosts iCloud removed on its own — a purged library, records gone
  /// without a tombstone — rather than a person deleting them. They go,
  /// and nothing they held is given back to another device's copy, but the
  /// keys this device made for them stay in its keychain.
  func vanish(_ ids: [UUID]? = nil) throws {
    try update { state in
      for id in ids ?? Array(state.records.keys) {
        guard var record = state.records[id], !record.deleted else { continue }
        record.deleted = true
        record.dirty = false
        record.vanished = true
        state.records[id] = record
      }
    }
  }

  /// After an encrypted-data reset the zone is gone but nothing was meant
  /// to be deleted, so this device's copy goes back up whole.
  func prepareReupload() throws {
    try update { state in
      for id in Array(state.records.keys) {
        guard var record = state.records[id] else { continue }
        record.systemFields = nil
        record.base = nil
        record.dirty = true
        // The zone these keys were sent to is gone.
        record.syncedKeyDigest = nil
        state.records[id] = record
      }
    }
  }

  func importLocalLibrary() {
    guard scope.hasPrefix("icloud:"), let database else { return }
    do {
      guard let source = try database.read(IdentitySnapshot.self, scope: "local"),
        !source.records.isEmpty else { return }
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
        var links = state.imports ?? [:]
        for (alias, link) in source.imports ?? [:] where state.records[link.id] != nil { links[alias] = link }
        state.imports = links
      }
      var emptied = source
      emptied.records = [:]
      emptied.bindings = [:]
      emptied.approvals = [:]
      emptied.passwordBindings = [:]
      emptied.adoptedAliases = [:]
      emptied.imports = nil
      try database.write(emptied, scope: "local")
      scheduleSync()
    } catch { recordProblem(error) }
  }

  func scheduleSync() { cloud?.enqueue() }

  func recordProblem(_ error: Error) { problem = error.localizedDescription }

  /// The private key this device would log in with, when it is one the
  /// other devices on this Apple ID should have too. A password is not.
  /// Nothing here is logged.
  func sharedPrivateKey(for profile: HostProfile) -> String? {
    privateKeyMaterial(profile: profile, bindings: snapshot.bindings)
  }

  /// A key this device has and has not yet sent. Marks the host so the next
  /// sync carries the key. A file that has not changed marks nothing.
  func noteKeysAwaitingSync() {
    do {
      try update(skippingUnchanged: true) { state in
        for id in state.records.keys {
          guard var record = state.records[id], !record.deleted, record.conflicts.isEmpty,
            record.forgetSharedKey != true else { continue }
          guard let pem = self.privateKeyMaterial(profile: record.profile, bindings: state.bindings) else { continue }
          if record.syncedKeyDigest != Self.keyDigest(pem) {
            record.dirty = true
            state.records[id] = record
          }
        }
      }
    } catch { recordProblem(error) }
  }

  /// Where a shared key is kept on every device: one id per host, so a key
  /// that arrives twice lands on the item the first copy already uses.
  static func syncedKeyID(for host: UUID) -> UUID { nameBasedUUID("synced-key:" + host.uuidString) }

  /// Digest of a private key. Hex, so it can sit in the library beside the
  /// host and still not be the key.
  static func keyDigest(_ pem: String) -> String {
    SHA256.hash(data: Data(pem.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static let clearedKey = "cleared"

  static func looksLikePrivateKey(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.utf8.count <= 64 * 1024
      && trimmed.contains("-----BEGIN ")
      && trimmed.contains("PRIVATE KEY")
      && trimmed.contains("-----END ")
  }

  private func privateKeyMaterial(profile: HostProfile, bindings: [UUID: LocalCredentialBinding]) -> String? {
    let binding = bindings[profile.authentication.primary.id]
    if let id = binding?.secretID {
      guard let pem = try? credentials.read(id), Self.looksLikePrivateKey(pem) else { return nil }
      return pem
    }
    let paths: [String]
    if let path = binding?.keyPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
      paths = [path]
    } else if binding?.defaultKeys == true {
      paths = defaultIdentityFiles
    } else {
      return nil
    }
    for path in paths {
      guard let pem = try? String(contentsOfFile: expandingTilde(path), encoding: .utf8),
        Self.looksLikePrivateKey(pem) else { continue }
      return pem
    }
    return nil
  }

  /// `nil` leaves whatever key this device already has. `""` withdraws the
  /// shared one. Anything else is the key, installed unless this device
  /// logs in with a file of its own — that file is what gets sent, and a
  /// copy arriving back must not replace it.
  private func take(_ privateKey: String?, for id: UUID, in state: inout IdentitySnapshot) throws {
    guard var record = state.records[id], !record.deleted, let privateKey else { return }
    let credential = record.profile.authentication.primary.id
    let trimmed = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      if state.bindings[credential]?.secretID == Self.syncedKeyID(for: id) {
        state.bindings[credential] = nil
      }
      record.forgetSharedKey = nil
      record.syncedKeyDigest = Self.clearedKey
      state.records[id] = record
      return
    }
    guard Self.looksLikePrivateKey(privateKey) else { return }
    record.syncedKeyDigest = Self.keyDigest(privateKey)
    record.forgetSharedKey = nil
    state.records[id] = record
    if Self.keepsOwnKeyFile(state.bindings[credential]) { return }
    let secretID = Self.syncedKeyID(for: id)
    if (try? credentials.read(secretID)) != privateKey {
      try credentials.write(privateKey, id: secretID, label: record.profile.label)
    }
    let publicKey = state.bindings[credential]?.secretID == secretID ? state.bindings[credential]?.publicKey : nil
    state.bindings[credential] = LocalCredentialBinding(credentialID: credential, secretID: secretID, publicKey: publicKey)
  }

  private static func keepsOwnKeyFile(_ binding: LocalCredentialBinding?) -> Bool {
    guard let binding else { return false }
    if let path = binding.keyPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty { return true }
    return binding.defaultKeys == true
  }

  private static func hasKey(_ binding: LocalCredentialBinding?) -> Bool {
    guard let binding else { return false }
    if binding.secretID != nil { return true }
    if let path = binding.keyPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty { return true }
    return binding.defaultKeys == true
  }

  private static func keyChoiceChanged(from previous: LocalCredentialBinding?, to binding: LocalCredentialBinding?) -> Bool {
    previous?.secretID != binding?.secretID || previous?.keyPath != binding?.keyPath
      || previous?.defaultKeys != binding?.defaultKeys
  }
}
