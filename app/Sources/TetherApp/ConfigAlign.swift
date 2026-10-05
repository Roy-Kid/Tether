import Foundation

/// How this Mac's SSH configuration has fallen behind the library, and the
/// edits that would let `ssh` reach what the library says.
///
/// The library stays the source of truth. A stanza someone edited still
/// updates its host (`ConfigImport`); that direction never writes. The other
/// direction — a host changed in Tether, or one that arrived from another
/// device — is written only when a person agrees, and only into the main
/// file. A file that file includes is not touched. Comments, jump hosts and
/// every setting the library does not represent stay where they are.
enum ConfigAlign {
  enum Edit: Equatable, Hashable, Sendable {
    /// A single-name stanza of the main file takes this face. `from` is the
    /// stanza's current name when the library renamed it.
    case update(HostFace, from: String?)
    /// No stanza of this name anywhere. Added to the main file.
    case append(HostFace, keyPath: String?)
    /// The host was deleted in Tether and its stanza is still in the main file.
    case remove(String)
    /// The stanza lives in a file this app does not edit. A block at the top
    /// of the main file is read first, so `ssh` takes this face.
    case cover(HostFace, keyPath: String?)
  }

  struct Plan: Equatable, Hashable, Sendable {
    var edits: [Edit]

    var isEmpty: Bool { edits.isEmpty }

    var title: String { "Update SSH configuration?" }

    /// Which hosts, on one line. The button already says what happens to them.
    var message: String? {
      let names = edits.map(\.name)
      guard !names.isEmpty else { return nil }
      if names.count <= 4 { return names.joined(separator: ", ") }
      return names.prefix(4).joined(separator: ", ") + ", +\(names.count - 4)"
    }
  }

  struct Input {
    var entries: [SSHConfig.Entry]
    var records: [UUID: SharedHostRecord]
    var links: [String: ImportLink]
    /// Which file's key this host logs in with, when the configuration is
    /// where that key lives. A key kept only in the keychain has no path.
    var keyPaths: [UUID: String]
    /// The file that may be edited. A stanza that names another is only read.
    var file: String
    var defaultUser: String
  }

  /// A name that can be one `Host` token. A pattern, a blank, or a name ssh
  /// would split is not a host this write can add.
  static func isAlias(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix("-")
      && !name.contains(where: { $0.isWhitespace || $0.isNewline || "*?!#\"'\\".contains($0) })
  }

  static func plan(_ input: Input) -> Plan {
    var edits: [Edit] = []
    var used: Set<String> = []
    let records = input.records.values.sorted {
      ($0.profile.label, $0.profile.id.uuidString) < ($1.profile.label, $1.profile.id.uuidString)
    }

    for record in records where !record.deleted && record.profile.id != Host.localID {
      let face = HostFace(record.profile)
      guard isAlias(face.name) else { continue }
      let key = input.keyPaths[record.profile.id]

      if let entry = input.entries.first(where: { $0.alias == face.name }) {
        used.insert(entry.alias)
        guard HostFace(entry, defaultUser: input.defaultUser) != face else { continue }
        if owns(entry, input) {
          edits.append(.update(face, from: nil))
        } else {
          edits.append(.cover(face, keyPath: key))
        }
        continue
      }

      if let alias = linkAlias(of: record.profile.id, input: input),
        let entry = input.entries.first(where: { $0.alias == alias }),
        owns(entry, input), isAlias(alias), !used.contains(alias)
      {
        used.insert(alias)
        edits.append(.update(face, from: alias))
        continue
      }

      edits.append(.append(face, keyPath: key))
    }

    for alias in input.links.keys.sorted() {
      guard let link = input.links[alias],
        let record = input.records[link.id], record.deleted,
        let entry = input.entries.first(where: { $0.alias == alias }),
        owns(entry, input), !used.contains(alias)
      else { continue }
      edits.append(.remove(alias))
    }
    return Plan(edits: edits)
  }

  /// Whether `config` — read the way `ssh` reads it, includes included —
  /// already says what `plan` would write.
  static func resolves(_ plan: Plan, in config: SSHConfig, defaultUser: String) -> Bool {
    for edit in plan.edits {
      switch edit {
      case .remove(let alias):
        if config.entries.contains(where: { $0.alias == alias }) { return false }
      case .update(let face, _), .append(let face, _), .cover(let face, _):
        guard let entry = config.entries.first(where: { $0.alias == face.name }),
          HostFace(entry, defaultUser: defaultUser) == face
        else { return false }
      }
    }
    return true
  }

  private static func owns(_ entry: SSHConfig.Entry, _ input: Input) -> Bool {
    entry.file == nil || entry.file == input.file
  }

  private static func linkAlias(of id: UUID, input: Input) -> String? {
    input.links.filter { $0.value.id == id }.keys.sorted().first
  }
}

extension ConfigAlign.Edit {
  var name: String {
    switch self {
    case .update(let face, _), .append(let face, _), .cover(let face, _): face.name
    case .remove(let alias): alias
    }
  }
}

/// The text of `~/.ssh/config` with one agreed alignment applied.
///
/// In place, where the stanza is a single name in this file. Where that
/// cannot win — a `Host *` above it, or a stanza that lives in an included
/// file — the same face is also written in a marked block at the top, which
/// `ssh` reads first. The block is replaced wholesale on the next agreement,
/// never stacked.
enum SSHConfigRewrite {
  static let beginMark = "# Begin Tether hosts"
  static let endMark = "# End Tether hosts"

  static func applying(
    _ edits: [ConfigAlign.Edit], to text: String, defaultUser: String, forceCover: Bool = false
  ) -> String {
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = split(text)
    lines = strip(lines)
    for edit in edits {
      switch edit {
      case .remove(let alias):
        remove(alias, from: &lines)
      case .update(let face, let from):
        rewrite(face, named: from ?? face.name, in: &lines)
      case .append(let face, let keyPath):
        insert(face, keyPath: keyPath, in: &lines)
      case .cover:
        break
      }
    }
    let covered = forceCover ? positive(edits) : positive(edits).filter { $0.forced } + drifting(edits, in: lines, defaultUser: defaultUser)
    if !covered.isEmpty {
      var prefix = block(covered)
      if !lines.isEmpty { prefix.append("") }
      lines.insert(contentsOf: prefix, at: 0)
    }
    return render(lines, newline: newline)
  }

  /// A face the marked block has to state, and the key the new stanza offers.
  fileprivate struct Covered {
    var face: HostFace
    var keyPath: String?
    /// An included file. The block is the only place this file can say it.
    var forced: Bool
  }

  private static func positive(_ edits: [ConfigAlign.Edit]) -> [Covered] {
    edits.compactMap { edit in
      switch edit {
      case .update(let face, _): return Covered(face: face, keyPath: nil, forced: false)
      case .append(let face, let key): return Covered(face: face, keyPath: key, forced: false)
      case .cover(let face, let key): return Covered(face: face, keyPath: key, forced: true)
      case .remove: return nil
      }
    }
  }

  /// Faces an in-place edit did not make `ssh` resolve, judged on this file
  /// alone. An included file is not visible here; the caller asks again with
  /// includes and, if it must, writes the block for every face.
  private static func drifting(
    _ edits: [ConfigAlign.Edit], in lines: [String], defaultUser: String
  ) -> [Covered] {
    let config = SSHConfig(render(lines, newline: "\n"))
    return positive(edits).filter { cover in
      guard !cover.forced else { return false }
      guard let entry = config.entries.first(where: { $0.alias == cover.face.name }) else { return true }
      return HostFace(entry, defaultUser: defaultUser) != cover.face
    }
  }

  private static func block(_ covers: [Covered]) -> [String] {
    var lines = [beginMark]
    for (index, cover) in covers.enumerated() {
      if index > 0 { lines.append("") }
      lines.append(contentsOf: stanza(cover.face, keyPath: cover.keyPath))
    }
    lines.append(endMark)
    return lines
  }

  private static func stanza(_ face: HostFace, keyPath: String?) -> [String] {
    var lines = [
      "Host \(face.name)",
      "  HostName \(quoted(face.hostName))",
      "  User \(quoted(face.user))",
    ]
    if face.port != 22 { lines.append("  Port \(face.port)") }
    if let keyPath, !keyPath.isEmpty { lines.append("  IdentityFile \(quoted(keyPath))") }
    return lines
  }

  private static func quoted(_ value: String) -> String {
    value.contains(where: { $0 == " " || $0 == "\t" || $0 == "#" }) ? "\"\(value)\"" : value
  }

  private struct Span {
    var host: Int
    var end: Int
    var single: Bool
    var alias: String
  }

  private static func spans(in lines: [String]) -> [Span] {
    var marks: [(index: Int, single: Bool, alias: String)] = []
    for (index, line) in lines.enumerated() {
      guard let found = directive(line), found.keyword == "host" || found.keyword == "match" else { continue }
      let words = tokens(found.value)
      let single = found.keyword == "host" && words.count == 1 && ConfigAlign.isAlias(words[0])
      marks.append((index, single, words.first ?? ""))
    }
    return marks.enumerated().map { offset, mark in
      Span(host: mark.index, end: offset + 1 < marks.count ? marks[offset + 1].index : lines.count,
        single: mark.single, alias: mark.alias)
    }
  }

  private static func span(_ alias: String, in lines: [String]) -> Span? {
    spans(in: lines).first { $0.single && $0.alias == alias }
  }

  @discardableResult
  private static func rewrite(_ face: HostFace, named alias: String, in lines: inout [String]) -> Bool {
    guard let found = span(alias, in: lines) else { return false }
    if face.name != alias {
      guard span(face.name, in: lines) == nil else { return false }
      lines[found.host] = renamed(lines[found.host], to: face.name)
    }
    let body = assign(Array(lines[(found.host + 1)..<found.end]), face: face)
    lines.replaceSubrange((found.host + 1)..<found.end, with: body)
    return true
  }

  /// Sets `HostName`, `User` and `Port` without moving any other line.
  /// A value `ssh` already takes from the line is left byte for byte, so a
  /// comment on it survives. Port 22 is the default: a `Port` line that says
  /// otherwise is removed, and none is added.
  private static func assign(_ body: [String], face: HostFace) -> [String] {
    var body = body
    var cursor = 0
    func ensure(keyword: String, canonical: String, value: String?) {
      let matches = body.indices.filter { directive(body[$0])?.keyword == keyword }
      guard let value else {
        for index in matches.reversed() { body.remove(at: index) }
        return
      }
      if let first = matches.first {
        if tokens(directive(body[first])?.value ?? "").first != value {
          body[first] = replaced(body[first], canonical: canonical, value: value)
        }
        for index in matches.dropFirst().reversed() { body.remove(at: index) }
        cursor = body.indices.filter { directive(body[$0])?.keyword == keyword }.first.map { $0 + 1 } ?? cursor
        return
      }
      let indent = body.lazy.compactMap(settingIndent).first ?? "  "
      body.insert("\(indent)\(canonical) \(quoted(value))", at: cursor)
      cursor += 1
    }
    ensure(keyword: "hostname", canonical: "HostName", value: face.hostName)
    ensure(keyword: "user", canonical: "User", value: face.user)
    ensure(keyword: "port", canonical: "Port", value: face.port == 22 ? nil : String(face.port))
    return body
  }

  private static func settingIndent(_ line: String) -> String? {
    guard directive(line) != nil else { return nil }
    return String(line.prefix(while: { $0 == " " || $0 == "\t" }))
  }

  private static func replaced(_ line: String, canonical: String, value: String) -> String {
    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let keyword = trimmed.prefix(while: { !$0.isWhitespace && $0 != "=" })
    let equals = trimmed.dropFirst(keyword.count).first == "="
    let word = keyword.isEmpty ? Substring(canonical) : keyword
    return "\(indent)\(word)\(equals ? "=" : " ")\(quoted(value))"
  }

  private static func renamed(_ line: String, to alias: String) -> String {
    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let keyword = trimmed.prefix(while: { !$0.isWhitespace && $0 != "=" })
    return "\(indent)\(keyword.isEmpty ? "Host" : String(keyword)) \(alias)"
  }

  private static func insert(_ face: HostFace, keyPath: String?, in lines: inout [String]) {
    guard span(face.name, in: lines) == nil else { return }
    var adding = stanza(face, keyPath: keyPath)
    if let index = lines.firstIndex(where: isWildcard) {
      adding.append("")
      lines.insert(contentsOf: adding, at: index)
    } else {
      if lines.last?.isEmpty == false { lines.append("") }
      lines.append(contentsOf: adding)
    }
  }

  private static func isWildcard(_ line: String) -> Bool {
    guard let found = directive(line) else { return false }
    if found.keyword == "match" { return true }
    guard found.keyword == "host" else { return false }
    let words = tokens(found.value)
    return !(words.count == 1 && ConfigAlign.isAlias(words[0]))
  }

  private static func remove(_ alias: String, from lines: inout [String]) {
    guard let found = span(alias, in: lines) else { return }
    lines.removeSubrange(found.host..<found.end)
  }

  /// Drops a block this wrote earlier, and the blank line that separated it.
  private static func strip(_ lines: [String]) -> [String] {
    var kept: [String] = []
    var skipping = false
    var removed = false
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == beginMark {
        skipping = true
        removed = true
        continue
      }
      if skipping {
        if trimmed == endMark { skipping = false }
        continue
      }
      kept.append(line)
    }
    if removed, kept.first?.isEmpty == true { kept.removeFirst() }
    return kept
  }

  private static func split(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    if text.hasSuffix("\n"), lines.last == "" { lines.removeLast() }
    return lines
  }

  private static func render(_ lines: [String], newline: String) -> String {
    guard !lines.isEmpty else { return "" }
    return lines.joined(separator: newline) + newline
  }
}
