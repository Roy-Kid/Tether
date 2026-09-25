import Foundation

/// An OpenSSH client configuration file, read for the hosts it describes and
/// edited without disturbing anything else it says.
///
/// The file is the store, and almost none of it is ours. A person's config
/// carries `ControlMaster`, `ForwardAgent`, a comment reminding them which
/// machine is which — none of which this app understands, and all of which it
/// would delete if it parsed the file into a model and wrote the model back.
///
/// So nothing is written back. What is parsed is an *index into the lines*,
/// and an edit rewrites only the lines it owns. Everything else survives
/// because it was never touched.
struct SSHConfig: Equatable {
  /// Every line of the file, verbatim and in order.
  private(set) var lines: [String]

  init(_ text: String) {
    // A file ending in a newline would otherwise gain an empty last line that
    // grows by one every time it is written.
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    self.lines = lines
  }

  var text: String {
    lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Reading

  /// One host, with every setting this app understands already resolved.
  struct Entry: Equatable {
    var alias: String
    var hostName: String
    var user: String?
    var port: UInt16?
    var identityFile: String?
  }

  /// A `Host` stanza: its patterns and where it sits in the file.
  private struct Block {
    var patterns: [String]
    /// The `Host` line itself.
    var start: Int
    /// One past the last line that belongs to this stanza.
    var end: Int
  }

  /// Every host the file names, in the order it names them.
  ///
  /// Only stanzas whose first pattern is a literal name. `Host *` and its
  /// relatives are settings for other hosts rather than hosts of their own,
  /// and listing them would offer a person a machine called `*` to connect to.
  var entries: [Entry] {
    let blocks = self.blocks
    return blocks.compactMap { block in
      guard let alias = block.patterns.first, isLiteral(alias) else { return nil }
      // Resolved across every stanza that matches, first value winning, which
      // is what ssh itself does — so a `User` under `Host *` is the user this
      // app will offer, exactly as it is the user ssh would use.
      let settings = resolved(alias: alias, in: blocks)
      return Entry(
        alias: alias,
        hostName: settings["hostname"] ?? alias,
        user: settings["user"],
        port: settings["port"].flatMap(UInt16.init),
        // Exactly as written. `~/.ssh/id_ed25519` is a path that survives the
        // account being moved and a config being shared between machines;
        // reading it, expanding it and writing it back would quietly replace
        // it with one that does neither.
        identityFile: settings["identityfile"])
    }
  }

  // MARK: - Writing

  /// Writes `entry`, replacing the stanza currently named `previous`.
  ///
  /// Only the four settings this app owns are touched. A stanza that also
  /// says `ForwardAgent yes` still says it afterwards, in the same place.
  mutating func write(_ entry: Entry, replacing previous: String? = nil) {
    guard let stanza = block(named: previous ?? entry.alias) else {
      append(entry)
      return
    }

    if stanza.patterns.first != entry.alias {
      // Only the first pattern. A stanza that answers to two names keeps the
      // other one: it was not this app's to remove.
      var patterns = stanza.patterns
      patterns[0] = entry.alias
      lines[stanza.start] = "Host " + patterns.map(quoted).joined(separator: " ")
    }

    // Re-found before each one, because setting a keyword that was absent
    // inserts a line and moves everything below it.
    set("HostName", entry.hostName, of: entry.alias)
    set("User", entry.user, of: entry.alias)
    // The default port is not written. `Port 22` in a file that never had one
    // is this app leaving its fingerprints on someone else's config — and an
    // existing line saying otherwise is removed, because a person who set the
    // port back to 22 meant it.
    set("Port", entry.port.flatMap { $0 == 22 ? nil : String($0) }, of: entry.alias)
    set("IdentityFile", entry.identityFile, of: entry.alias)
  }

  /// Removes the stanza named `alias`, and the blank line that separated it.
  mutating func remove(alias: String) {
    guard let stanza = block(named: alias) else { return }

    // Back off the trailing blanks and comments: a comment before the next
    // stanza is almost always about that one, and deleting a host should not
    // silently take someone's note with it.
    var last = stanza.end - 1
    while last > stanza.start, !isDirective(lines[last]) { last -= 1 }

    lines.removeSubrange(stanza.start...last)
    if stanza.start < lines.count,
      lines[stanza.start].trimmingCharacters(in: .whitespaces).isEmpty
    {
      lines.remove(at: stanza.start)
    }
  }

  private mutating func append(_ entry: Entry) {
    if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.append("")
    }
    lines.append("Host \(quoted(entry.alias))")
    lines.append("  HostName \(entry.hostName)")
    if let user = entry.user, !user.isEmpty { lines.append("  User \(user)") }
    if let port = entry.port, port != 22 { lines.append("  Port \(port)") }
    if let key = entry.identityFile, !key.isEmpty { lines.append("  IdentityFile \(key)") }
  }

  /// Sets one keyword inside a host's stanza, or removes it when there is no
  /// value.
  ///
  /// In place where the keyword already appears, so its indentation and its
  /// position among the person's other settings survive.
  private mutating func set(_ keyword: String, _ value: String?, of alias: String) {
    let blocks = self.blocks
    guard let block = blocks.first(where: { $0.patterns.first == alias }) else { return }
    let existing = (block.start + 1..<block.end).first {
      directive(lines[$0])?.keyword == keyword.lowercased()
    }

    guard let value, !value.isEmpty else {
      if let existing { lines.remove(at: existing) }
      return
    }

    if let existing {
      lines[existing] = indentation(of: lines[existing]) + "\(keyword) \(quoted(value))"
    } else if resolved(alias: alias, in: blocks)[keyword.lowercased()] != value {
      lines.insert(blockIndentation(block) + "\(keyword) \(quoted(value))", at: block.start + 1)
    }
    // Otherwise there is nothing to add: a stanza that matches this host
    // already says it. Writing it here as well would copy an inherited
    // setting into the host, and editing `Host *` afterwards would then
    // silently stop reaching it.
  }

  // MARK: - The index

  private var blocks: [Block] {
    var blocks: [Block] = []
    for (index, line) in lines.enumerated() {
      guard let directive = directive(line) else { continue }
      // `Match` opens a stanza too, and not one this app understands. Closing
      // the previous block at it is what stops its settings being read as the
      // previous host's.
      guard directive.keyword == "host" || directive.keyword == "match" else { continue }

      if !blocks.isEmpty { blocks[blocks.count - 1].end = index }
      if directive.keyword == "host" {
        blocks.append(Block(patterns: tokens(directive.value), start: index, end: lines.count))
      }
    }
    return blocks
  }

  private func block(named alias: String) -> Block? {
    blocks.first { $0.patterns.first == alias }
  }

  /// Every setting that applies to `alias`, first value winning.
  private func resolved(alias: String, in blocks: [Block]) -> [String: String] {
    var settings: [String: String] = [:]
    for block in blocks where matches(patterns: block.patterns, alias: alias) {
      for index in block.start + 1..<block.end {
        guard let directive = directive(lines[index]), directive.keyword != "host" else { continue }
        guard settings[directive.keyword] == nil else { continue }
        guard let first = tokens(directive.value).first else { continue }
        settings[directive.keyword] = first
      }
    }
    return settings
  }
}

// MARK: - Lines

extension SSHConfig {
  private func isDirective(_ line: String) -> Bool { directive(line) != nil }

  /// Splits a line into its keyword and the rest, or `nil` for a blank line
  /// or a comment.
  ///
  /// `Keyword value` and `Keyword=value` are the same line to ssh, so they
  /// are the same line here.
  private func directive(_ line: String) -> (keyword: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

    let separators = CharacterSet(charactersIn: " \t=")
    guard let split = trimmed.rangeOfCharacter(from: separators) else {
      return (trimmed.lowercased(), "")
    }
    let keyword = String(trimmed[trimmed.startIndex..<split.lowerBound]).lowercased()
    let value = trimmed[split.lowerBound...]
      .trimmingCharacters(in: separators.union(.whitespaces))
    return (keyword, value)
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

  private func quoted(_ value: String) -> String {
    value.contains(" ") ? "\"\(value)\"" : value
  }

  private func indentation(of line: String) -> String {
    String(line.prefix { $0 == " " || $0 == "\t" })
  }

  /// What the stanza's own settings are indented by, so an added one lines up
  /// with them rather than with the left margin.
  private func blockIndentation(_ block: Block) -> String {
    for index in block.start + 1..<block.end where isDirective(lines[index]) {
      return indentation(of: lines[index])
    }
    return "  "
  }
}

// MARK: - Patterns

/// Whether a pattern names one machine rather than a class of them.
private func isLiteral(_ pattern: String) -> Bool {
  !pattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "!" })
}

/// ssh's own rule: any pattern may match, and a negated one that matches
/// takes the stanza away again.
private func matches(patterns: [String], alias: String) -> Bool {
  var matched = false
  for pattern in patterns {
    if pattern.hasPrefix("!") {
      if glob(String(pattern.dropFirst()), alias) { return false }
    } else if glob(pattern, alias) {
      matched = true
    }
  }
  return matched
}

/// `*` and `?`, which is all ssh has.
private func glob(_ pattern: String, _ text: String) -> Bool {
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

/// The other direction, for a path this app obtained from a file picker.
///
/// A config full of `/Users/someone/...` is one that stops working the day it
/// is copied to another machine — which is a thing people do with this file.
func contractingHome(_ path: String) -> String {
  let home = NSHomeDirectory()
  guard path.hasPrefix(home + "/") else { return path }
  return "~" + path.dropFirst(home.count)
}

extension SSHConfig {
  /// Conservative import: configurations whose behavior cannot be represented are
  /// left available through the existing local OpenSSH entry.
  func importLimitations(alias: String) -> [String] {
    let structural = lines.compactMap(directive).filter { ["include", "match"].contains($0.keyword) }.map(\.keyword)
    let settings = resolved(alias: alias, in: blocks)
    let supported: Set<String> = ["hostname", "user", "port", "identityfile", "controlmaster", "controlpath", "controlpersist", "identitiesonly"]
    var issues = Set(structural + settings.keys.filter { !supported.contains($0) })
    if settings.values.contains(where: { $0.contains("%") || $0.contains("${") }) {
      // ControlPath expansion is local to OpenSSH, not part of the imported endpoint.
      if ["hostname", "user", "identityfile"].contains(where: { settings[$0]?.contains("%") == true || settings[$0]?.contains("${") == true }) {
        issues.insert("variable expansion")
      }
    }
    let keyCount = blocks.filter { matches(patterns: $0.patterns, alias: alias) }.reduce(0) { count, block in
      count + lines[(block.start + 1)..<block.end].compactMap(directive).filter { $0.keyword == "identityfile" }.count
    }
    if keyCount > 1 { issues.insert("multiple IdentityFile entries") }
    return issues.sorted()
  }
}
