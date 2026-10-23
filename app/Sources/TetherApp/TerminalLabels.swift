import Foundation

/// What one terminal can be called before twins are numbered.
struct TerminalLabel: Equatable {
  var id: UUID
  /// Rename Terminal. While set, activity does not change the chip.
  var pinned: String?
  /// Attached session name, when this terminal is a client of one.
  var session: String?
  /// Foreground program. Nil while the shell is at its prompt.
  var command: String?
  /// Last path component, or `~` for the home directory.
  var directory: String?
  /// `Terminal N`, kept for history and as the fallback.
  var serial: String
}

/// Chip titles for the terminals on one host, in strip order.
///
/// A pinned name is kept as typed. Otherwise the chip shows the attached session,
/// then the foreground program, then the directory, then `Terminal N`.
/// When two or more of those automatic names are the same word — several
/// `ssh` sessions, two checkouts of one repo — each gains a number in
/// strip order: `ssh 1`, `ssh 2`.
enum TerminalLabels {
  static func titles(_ rows: [TerminalLabel]) -> [UUID: String] {
    let bases = rows.map { base($0) }
    var counts: [String: Int] = [:]
    for item in bases where item.automatic {
      counts[item.text, default: 0] += 1
    }
    var seen: [String: Int] = [:]
    var result: [UUID: String] = [:]
    for (row, item) in zip(rows, bases) {
      let twins = item.automatic ? (counts[item.text] ?? 0) : 0
      if twins > 1 {
        let number = (seen[item.text] ?? 0) + 1
        seen[item.text] = number
        result[row.id] = "\(item.text) \(number)"
      } else {
        result[row.id] = item.text
      }
    }
    return result
  }

  /// The word Rename Terminal starts from: the pin, or the automatic name
  /// without its twin number.
  static func seed(_ row: TerminalLabel) -> String {
    base(row).text
  }

  /// A name saved before pins existed. `Terminal N` stays automatic.
  /// Anything else was typed, and stays pinned.
  static func restoredPin(name: String, pinned: String?) -> String? {
    if let pinned = cleaned(pinned) { return pinned }
    return isSerial(name) ? nil : cleaned(name)
  }

  static func directoryName(_ path: String?, home: String?) -> String? {
    guard var path, path.hasPrefix("/") else { return nil }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    if let home {
      var home = home
      while home.count > 1, home.hasSuffix("/") { home.removeLast() }
      if path == home { return "~" }
    }
    guard path != "/" else { return nil }
    let base = URL(fileURLWithPath: path).lastPathComponent
    return cleaned(base)
  }

  static func isSerial(_ name: String) -> Bool {
    guard let space = name.firstIndex(of: " "), name[..<space] == "Terminal" else { return false }
    let tail = name[name.index(after: space)...]
    return !tail.isEmpty && tail.allSatisfy(\.isNumber)
  }

  private static func base(_ row: TerminalLabel) -> (text: String, automatic: Bool) {
    if let pinned = cleaned(row.pinned) { return (pinned, false) }
    if let session = cleaned(row.session) { return (session, true) }
    if let command = cleaned(row.command) { return (command, true) }
    if let directory = cleaned(row.directory) { return (directory, true) }
    return (row.serial, true)
  }
}

extension TabSet {
  /// The word on this terminal's chip, including a twin number.
  func displayTitle(for id: UUID) -> String {
    guard let tab = tabs.first(where: { $0.id == id }) else {
      return extensions.first { $0.id == id }?.workspace.title ?? ""
    }
    let home = tab.host.isLocal ? NSHomeDirectory() : nil
    return TerminalLabels.titles(terminals(on: tab.host.id).map { label(for: $0, home: home) })[id] ?? tab.name
  }

  /// What Rename Terminal offers to edit.
  func renameSeed(for id: UUID) -> String {
    guard let tab = tabs.first(where: { $0.id == id }) else { return "" }
    let home = tab.host.isLocal ? NSHomeDirectory() : nil
    return TerminalLabels.seed(label(for: tab, home: home))
  }

  private func terminals(on host: UUID) -> [SessionTab] {
    let pages = workspaces.filter { $0.host.id == host }
    let ids = pages.flatMap(\.terminalIDs)
    let ordered = ids.compactMap { id in tabs.first { $0.id == id } }
    let rest = tabs.filter { $0.host.id == host && !ids.contains($0.id) }
    return ordered + rest
  }

  private func label(for tab: SessionTab, home: String?) -> TerminalLabel {
    let session = tab.attachments.lazy.compactMap { entry -> String? in
      let title = entry.attachment.tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      return title.isEmpty ? nil : title
    }.first
    return TerminalLabel(
      id: tab.id,
      pinned: tab.pinnedName,
      session: session,
      command: tab.foregroundCommand,
      directory: TerminalLabels.directoryName(tab.labelPath ?? tab.workingDirectory, home: home),
      serial: tab.name)
  }
}

extension TerminalLabels {
  fileprivate static func cleaned(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }
    return trimmed
  }
}
