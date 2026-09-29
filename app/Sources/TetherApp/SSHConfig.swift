import Foundation

/// An OpenSSH client configuration, read for the hosts it describes.
///
/// Read, never written. The file is the person's, and almost none of it is
/// this app's to understand — `ControlMaster`, `ForwardAgent`, a comment
/// reminding them which machine is which. The way to keep all of it is not to
/// hold the pen: Tether's own hosts go to a file of their own
/// (`OpenSSHExport`), which this one includes.
struct SSHConfig: Equatable {
  /// One host, with every setting this app understands already resolved.
  struct Entry: Equatable {
    var alias: String
    var hostName: String
    var user: String?
    var port: UInt16?
    var identityFile: String?
    /// The file whose `Host` line names it: `~/.ssh/config` itself, which
    /// Tether may edit, or one it includes, which Tether only reads.
    var file: String? = nil
  }

  /// A file an `Include` names, read.
  struct Source {
    var path: String
    var text: String
  }

  /// One `Keyword value` line.
  fileprivate struct Directive: Equatable {
    var keyword: String
    var value: String
  }

  /// A stanza, as ssh sees it once every `Include` has been read.
  fileprivate struct Block: Equatable {
    enum Kind: Equatable {
      case host([String])
      /// Criteria this reader does not evaluate; its settings are never
      /// applied, only looked at by `importLimitations`.
      case match
    }
    var kind: Kind
    /// The host patterns of every stanza an `Include` was read from. Each has
    /// to match as well: that is the only time ssh reads the included file.
    var conditions: [[String]] = []
    /// The file this stanza is written in.
    var file: String?
    /// Opened by this reader rather than written by a person — the settings
    /// before a file's first `Host`, or the rest of a stanza an `Include`
    /// interrupted. Never offered as a host of its own.
    var implied = false
    var settings: [Directive] = []

    func applies(to alias: String) -> Bool {
      guard case .host(let patterns) = kind else { return false }
      return sshPatternsMatch(patterns, alias)
        && conditions.allSatisfy { sshPatternsMatch($0, alias) }
    }
  }

  private var blocks: [Block]

  /// `include` answers one `Include` argument with every file it names, in
  /// the order ssh reads them. The default reads nothing. `file` is where
  /// `text` came from, for the entries it names.
  init(_ text: String, file: String? = nil, include: @escaping (String) -> [Source] = { _ in [] }) {
    // Whatever comes before the first `Host` applies to every host, exactly
    // as though it were written under `Host *`.
    var reader = Reader(include: include, blocks: [Block(kind: .host(["*"]), file: file, implied: true)])
    reader.read(text, file: file, depth: 0)
    blocks = reader.blocks
  }

  // MARK: - Reading

  /// Every host the files name, in the order they name them.
  ///
  /// Only stanzas whose first pattern is a literal name. `Host *` and its
  /// relatives are settings for other hosts rather than hosts of their own,
  /// and listing them would offer a person a machine called `*` to connect to.
  var entries: [Entry] {
    var seen: Set<String> = []
    return blocks.compactMap { block in
      guard !block.implied, case .host(let patterns) = block.kind,
        let alias = patterns.first, isLiteral(alias),
        block.applies(to: alias), seen.insert(alias).inserted
      else { return nil }
      // Resolved across every stanza that matches, first value winning, which
      // is what ssh itself does — so a `User` under `Host *` is the user this
      // app will offer, exactly as it is the user ssh would use.
      let settings = resolved(alias: alias)
      return Entry(
        alias: alias,
        hostName: settings["hostname"] ?? alias,
        user: settings["user"],
        port: settings["port"].flatMap(UInt16.init),
        // Exactly as written. `~/.ssh/id_ed25519` is a path that survives the
        // account being moved and a config being shared between machines.
        // The first one is the key ssh tries first.
        identityFile: settings["identityfile"],
        file: block.file)
    }
  }

  /// Every setting that reaches `alias`, in the order ssh reads them.
  private func applicable(to alias: String) -> [Directive] {
    blocks.filter { $0.applies(to: alias) }.flatMap(\.settings)
  }

  /// Every setting that applies to `alias`, first value winning.
  private func resolved(alias: String) -> [String: String] {
    var settings: [String: String] = [:]
    for directive in applicable(to: alias) where settings[directive.keyword] == nil {
      if let first = tokens(directive.value).first { settings[directive.keyword] = first }
    }
    return settings
  }
}

// MARK: - Import

extension SSHConfig {
  /// What ssh would do for this host that a profile made from its
  /// hostname, user, port and key would not.
  ///
  /// Only the settings that decide *where* a connection goes, *which*
  /// machine answers or *what* runs there. A profile that quietly skipped a
  /// jump host would reach a different machine, or none. Settings that tune
  /// ssh itself — keep-alives, the keychain, agent forwarding, ciphers — never
  /// decided any of that, and a config full of them under `Host *` is the
  /// ordinary case, not a reason to refuse.
  func importLimitations(alias: String) -> [String] {
    var issues: Set<String> = []
    for directive in applicable(to: alias) where Self.divergent.contains(directive.keyword) {
      issues.insert(directive.keyword)
    }
    // A `Match` block is not evaluated here. One that could change the
    // endpoint, the key, or the files ssh reads makes the answer unknowable.
    let unknowable = blocks.contains { block in
      block.kind == .match
        && block.conditions.allSatisfy { sshPatternsMatch($0, alias) }
        && block.settings.contains { Self.decisive.contains($0.keyword) }
    }
    if unknowable { issues.insert("match") }
    let settings = resolved(alias: alias)
    if ["hostname", "user", "identityfile"].contains(where: {
      settings[$0].map { $0.contains("%") || $0.contains("${") } ?? false
    }) {
      issues.insert("variable expansion")
    }
    return issues.sorted()
  }

  /// Settings under which ssh reaches another machine, or runs another thing.
  private static let divergent: Set<String> = [
    "proxyjump", "proxycommand", "hostkeyalias", "canonicalizehostname",
    "remotecommand", "sessiontype",
  ]
  /// Everything a `Match` block could say that would change the import.
  private static let decisive = divergent.union(["hostname", "user", "port", "identityfile", "include"])
}

// MARK: - Files

extension SSHConfig {
  /// Reads `url` and everything it includes.
  ///
  /// A relative `Include` is relative to the directory the config lives in,
  /// `~/.ssh` for the file this app reads — where ssh looks for it too.
  /// `skipping` names files not to follow: Tether's own export is included by
  /// the person's config, and reading it back would list every managed host
  /// a second time as a stranger.
  static func read(_ url: URL, skipping: [URL] = []) throws -> SSHConfig {
    let base = url.deletingLastPathComponent()
    let skipped = Set(skipping.map { $0.resolvingSymlinksInPath().path })
    return SSHConfig(try String(contentsOf: url, encoding: .utf8), file: url.path) { argument in
      let expanded = expandingTilde(argument)
      let pattern = expanded.hasPrefix("/") ? expanded : base.appending(path: expanded).path
      return globbed(pattern)
        .filter { !skipped.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
        // A file that cannot be read is skipped, as ssh skips a pattern
        // that matches nothing.
        .compactMap { path in (try? String(contentsOfFile: path, encoding: .utf8)).map { Source(path: path, text: $0) } }
    }
  }

  /// Every file this configuration was read from, the included ones too.
  var files: Set<String> { Set(blocks.compactMap(\.file)) }
}

/// `Include` is expanded with glob(3), and its matches read in the sorted
/// order glob returns them.
private func globbed(_ pattern: String) -> [String] {
  var matches = glob_t()
  defer { Darwin.globfree(&matches) }
  guard Darwin.glob(pattern, 0, nil, &matches) == 0 else { return [] }
  return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { String(cString: $0) } }
}

// MARK: - Parsing

/// Turns text into blocks, following `Include` where ssh would.
private struct Reader {
  let include: (String) -> [SSHConfig.Source]
  var blocks: [SSHConfig.Block]

  /// ssh follows includes this deep and no deeper; it is also what ends a
  /// file that includes itself.
  static let maxDepth = 16

  mutating func read(_ text: String, file: String?, depth: Int) {
    for line in text.components(separatedBy: .newlines) {
      guard let directive = directive(line) else { continue }
      let current = blocks[blocks.count - 1]
      switch directive.keyword {
      case "host":
        blocks.append(.init(kind: .host(tokens(directive.value)), conditions: current.conditions, file: file))
      case "match":
        blocks.append(.init(kind: .match, conditions: current.conditions, file: file))
      case "include":
        guard case .host(let patterns) = current.kind else {
          // Read or not depending on a `Match` this reader cannot evaluate.
          blocks[blocks.count - 1].settings.append(directive)
          continue
        }
        guard depth < Self.maxDepth else { continue }
        for argument in tokens(directive.value) {
          for source in include(argument) {
            // Each file begins under the stanza that included it, and its
            // own `Host` lines apply only where that stanza does: ssh never
            // reads the file otherwise.
            blocks.append(.init(kind: current.kind, conditions: current.conditions + [patterns], file: source.path, implied: true))
            read(source.text, file: source.path, depth: depth + 1)
          }
        }
        // The lines after `Include` still belong to the stanza it interrupted.
        blocks.append(.init(kind: current.kind, conditions: current.conditions, file: file, implied: true))
      default:
        blocks[blocks.count - 1].settings.append(directive)
      }
    }
  }
}

/// Splits a line into its keyword and the rest, or `nil` for a blank line or
/// a comment.
///
/// `Keyword value` and `Keyword=value` are the same line to ssh, so they are
/// the same line here.
private func directive(_ line: String) -> SSHConfig.Directive? {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

  let separators = CharacterSet(charactersIn: " \t=")
  guard let split = trimmed.rangeOfCharacter(from: separators) else {
    return .init(keyword: trimmed.lowercased(), value: "")
  }
  let keyword = String(trimmed[trimmed.startIndex..<split.lowerBound]).lowercased()
  let value = trimmed[split.lowerBound...].trimmingCharacters(in: separators.union(.whitespaces))
  return .init(keyword: keyword, value: value)
}

/// Splits a value into words, keeping a quoted one whole.
private func tokens(_ value: String) -> [String] {
  var tokens: [String] = []
  var current = ""
  var quoting = false

  for character in value {
    if character == "\"" {
      quoting.toggle()
    } else if !quoting, character == " " || character == "\t" {
      if !current.isEmpty { tokens.append(current) }
      current = ""
    } else {
      current.append(character)
    }
  }
  if !current.isEmpty { tokens.append(current) }
  return tokens
}

// MARK: - Patterns

/// Whether a pattern names one machine rather than a class of them.
private func isLiteral(_ pattern: String) -> Bool {
  !pattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "!" })
}

/// ssh's own rule, for `Host` lines and `known_hosts` alike: any pattern may
/// match, and a negated one that matches takes the whole list away again.
func sshPatternsMatch(_ patterns: [String], _ alias: String) -> Bool {
  var matched = false
  for pattern in patterns {
    if pattern.hasPrefix("!") {
      if wildcard(String(pattern.dropFirst()), alias) { return false }
    } else if wildcard(pattern, alias) {
      matched = true
    }
  }
  return matched
}

/// `*` and `?`, which is all ssh has.
private func wildcard(_ pattern: String, _ text: String) -> Bool {
  let pattern = Array(pattern)
  let text = Array(text)
  var memo: [[Bool?]] = Array(
    repeating: Array(repeating: nil, count: text.count + 1), count: pattern.count + 1)

  func match(_ p: Int, _ t: Int) -> Bool {
    if let known = memo[p][t] { return known }
    let answer: Bool
    if p == pattern.count {
      answer = t == text.count
    } else if pattern[p] == "*" {
      answer = match(p + 1, t) || (t < text.count && match(p, t + 1))
    } else if t < text.count && (pattern[p] == "?" || pattern[p] == text[t]) {
      answer = match(p + 1, t + 1)
    } else {
      answer = false
    }
    memo[p][t] = answer
    return answer
  }
  return match(0, 0)
}

// MARK: - Keys

/// The files OpenSSH tries when a host names no `IdentityFile`.
///
/// Order matches OpenSSH's `DEFAULT_IDENTITY_FILES`. A different set, or a
/// different order, would log in as a different person than `ssh` would —
/// or fail where `ssh` succeeded.
let defaultIdentityFiles = [
  "~/.ssh/id_rsa",
  "~/.ssh/id_ecdsa",
  "~/.ssh/id_ecdsa_sk",
  "~/.ssh/id_ed25519",
  "~/.ssh/id_ed25519_sk",
  "~/.ssh/id_dsa",
]

/// Private keys this host will offer, as written (with `~`).
///
/// A configured `IdentityFile` is exclusive: that is the key, and the
/// defaults are not also tried — the same as `IdentitiesOnly yes`, which is
/// how a host that names a key is almost always written. Without one, the
/// defaults that actually exist on disk are offered.
func identityFiles(
  for host: Host,
  readable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
) -> [String] {
  if host.offersConfiguredKey, let path = host.keyPath {
    return [path]
  }
  return defaultIdentityFiles.filter { readable(expandingTilde($0)) }
}

/// `~/.ssh/id_ed25519` is a path a person can read; this app has to open it.
func expandingTilde(_ path: String) -> String {
  path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
}
