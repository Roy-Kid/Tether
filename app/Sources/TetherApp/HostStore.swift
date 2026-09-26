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

  /// Hops visited before this machine, first to last. Empty when `ssh` would
  /// dial it directly.
  var jumps: [JumpTarget] = []

  /// Set when `ProxyJump` cannot be followed — a cycle, a token that is not
  /// a host. Connecting anyway would reach a different machine than `ssh`.
  var jumpProblem: String? = nil

  /// An `IdentityFile` in the ssh config is already a credential, so a
  /// password is not required to start the handshake. `ssh host` would not
  /// ask for one either.
  var offersConfiguredKey: Bool {
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

/// One hop in front of a saved host. The username is already resolved,
/// including the account name `ssh` would use when the stanza names none.
struct JumpTarget: Hashable {
  var hostname: String
  var port: UInt16
  var username: String
  var keyPath: String?
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

/// The saved hosts: `~/.ssh/config`, and nothing else.
///
/// One file, and not one of ours. A person who keeps machines in an ssh
/// config already has them written down somewhere that `ssh`, `scp`, `rsync`
/// and their editor all read; a second list inside this app would be a copy
/// of that, and a copy is a thing that goes out of date. So a host added here
/// is a stanza added there, and a host added there appears here.
///
/// No passwords and no keys. Those live in the keychain, behind
/// [`SecretStore`] — a file pretending to be a keychain would be worse than
/// asking every time, because it looks like security to the person trusting
/// it (spec §18).
@MainActor
@Observable
final class HostStore {
  private(set) var hosts: [Host] = []
  var search: String = ""

  /// Why the file could not be read or written, for the one place that says
  /// so. Silence would mean a person adds a host, sees nothing happen, and
  /// has no way to find out that their config is read-only.
  private(set) var problem: String?

  private let location: URL
  private let secrets: any SecretStore
  /// The file as it was last read, so an edit rewrites the lines it owns
  /// rather than replacing everything the person put there.
  private var config = SSHConfig("")
  /// Set when the file exists and could not be read. Nothing is written while
  /// it is: an edit would replace a config this app never saw with one built
  /// from an empty file, and there is no other copy of it.
  private var unreadable = false

  /// Every host a person can open, the local machine first.
  ///
  /// Built rather than stored. The local machine is not a saved host and must
  /// not become one: writing it to `hosts.json` would mean a file that has to
  /// be migrated when the account name changes, and a row a person could
  /// delete to make their own computer unreachable.
  ///
  /// It is absent where the system does not allow it. iOS has no `fork`/`exec`
  /// outside the sandbox, and offering a row that could only ever fail would
  /// be worse than not offering one.
  var listed: [Host] {
    TerminalSession.isLocalAvailable ? [.local] + hosts : hosts
  }

  var filtered: [Host] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return listed }
    return listed.filter {
      $0.label.lowercased().contains(query)
        || $0.hostname.lowercased().contains(query)
        || $0.username.lowercased().contains(query)
    }
  }

  init(location override: URL? = nil, secrets: any SecretStore = Keychain()) {
    self.secrets = secrets
    location = override ?? Self.sshConfig
    load()
  }

  /// Where OpenSSH looks, which is the only reason this is the path.
  static var sshConfig: URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appending(path: ".ssh", directoryHint: .isDirectory)
      .appending(path: "config")
  }

  /// What to call the file in the one place that names it.
  var locationDescription: String {
    location.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }

  /// Reads the file again.
  ///
  /// Called when the app comes back to the front, because the file is shared:
  /// a host added with an editor while this was in the background is a host
  /// this should be showing.
  func reload() {
    load()
  }

  func save(_ host: Host, password: String? = nil) {
    // There is nothing to save about the machine this is running on, and
    // nothing to edit either: a label, a hostname, a port and a user are four
    // answers it already knows. Refused here as well as hidden in the
    // interface, so a future caller cannot write one into the file by
    // accident.
    guard !host.isLocal, !unreadable else { return }

    let alias = Self.alias(of: host)
    guard !alias.isEmpty else { return }
    let previous = hosts.first { $0.id == host.id }.map(Self.alias(of:))

    config.write(
      SSHConfig.Entry(
        alias: alias,
        hostName: host.hostname,
        user: host.username.isEmpty ? nil : host.username,
        port: host.port,
        identityFile: host.keyPath.map(contractingHome)),
      replacing: previous)

    // A renamed host is a differently identified one, because the name *is*
    // the identity in an ssh config. The password someone asked this app to
    // keep follows the host they meant rather than the string they changed.
    if let previous, previous != alias {
      var renamed = host
      renamed.id = Host.id(forAlias: alias)
      renamed.label = alias
      move(secret: Host.id(forAlias: previous), to: renamed)
    }
    persist()

    // After the file write: `persist` reloads from disk and would otherwise
    // clear a keychain error set here. The editor's host may still carry a
    // random `blank()` id — the item has to live under the stanza name, or
    // the next launch would ask again. `nil` leaves whatever was stored.
    if let password {
      var identified = host
      identified.id = Host.id(forAlias: alias)
      identified.label = alias
      do {
        if password.isEmpty {
          try secrets.forget(identified.id)
        } else {
          try secrets.remember(password, for: identified)
        }
        load()
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  func delete(_ host: Host) {
    // Deleting the local machine would mean a person could make their own
    // computer unreachable from an app running on it, and nothing would
    // bring it back.
    guard !host.isLocal, !unreadable else { return }

    config.remove(alias: Self.alias(of: host))
    // A host that no longer exists must not leave a password behind. If the
    // keychain refuses, the item survives as an entry with no host — which is
    // exactly what the saved-passwords list in settings shows and lets a
    // person delete. A failure here is visible somewhere rather than nowhere.
    try? secrets.forget(host.id)
    persist()
  }

  /// The stanza name for a host: what a person called it, or the address when
  /// they called it nothing.
  private static func alias(of host: Host) -> String {
    let label = host.label.trimmingCharacters(in: .whitespaces)
    return label.isEmpty ? host.hostname.trimmingCharacters(in: .whitespaces) : label
  }

  private func move(secret previous: UUID, to host: Host) {
    guard let password = try? secrets.password(for: previous) else { return }
    try? secrets.remember(password, for: host)
    try? secrets.forget(previous)
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: location.path) else {
      // Not a failure. Someone who has never used ssh from this account has
      // an empty list and a file that will be written the first time they
      // add a host.
      config = SSHConfig("")
      hosts = []
      problem = nil
      unreadable = false
      return
    }

    do {
      config = SSHConfig(try String(contentsOf: location, encoding: .utf8))
      problem = nil
      unreadable = false
    } catch {
      // Left exactly as it is. The alternative — starting from an empty file
      // — would mean the next host added replaces a person's whole ssh
      // config, and there is no other copy of it.
      problem = "Could not read \(locationDescription): \(error.localizedDescription)"
      unreadable = true
      return
    }

    let remembered = Set((try? secrets.saved())?.map(\.id) ?? [])
    hosts = config.entries.map { entry in
      let route = route(for: entry.alias)
      return Host(
        id: Host.id(forAlias: entry.alias),
        label: entry.alias,
        hostname: entry.hostName,
        port: entry.port ?? 22,
        username: entry.user ?? defaultUserName(),
        remembersPassword: remembered.contains(Host.id(forAlias: entry.alias)),
        keyPath: entry.identityFile,
        jumps: route.hops,
        jumpProblem: route.problem)
    }
  }

  /// The hops in front of `alias`, or why they cannot be followed.
  private func route(for alias: String) -> (hops: [JumpTarget], problem: String?) {
    switch config.jumps(for: alias) {
    case .success(let hops):
      let targets = hops.map { hop in
        JumpTarget(
          hostname: hop.hostName,
          port: hop.port,
          username: hop.user ?? defaultUserName(),
          keyPath: hop.identityFile)
      }
      return (targets, nil)
    case .failure(let error):
      return ([], message(for: error, alias: alias))
    }
  }

  private func message(for error: SSHConfig.JumpError, alias: String) -> String {
    switch error {
    case .cycle(let name):
      return "ProxyJump for \(alias) cycles through \(name)."
    case .tooLong:
      return "ProxyJump for \(alias) is too long."
    case .malformed(let token):
      return "ProxyJump for \(alias) has an unreadable hop (\(token))."
    }
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(
        at: location.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try config.text.write(to: location, atomically: true, encoding: .utf8)
      // ssh refuses a config anyone else can write, and a file this app
      // created with the default mask is one it would then refuse.
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: location.path)
      problem = nil
    } catch {
      problem = "Could not write \(locationDescription): \(error.localizedDescription)"
    }
    load()
  }
}
