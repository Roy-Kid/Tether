import Foundation
import Tether

/// The far-side tty of this tab's shell, when the producer does not record one.
///
/// A local shell's name is its pty. An SSH shell's tmux client is the pty on
/// the far side, which this process never sees: `ssh -tt` and a russh channel
/// both leave `terminalName` empty, so the tab could not tell that its own
/// shell was already the client and covered it with a second one. The exec
/// that lists processes is another channel on the same connection, so the
/// shell is a sibling session under that connection's sshd.
enum ShellTTY {
  static let listCommand =
    "printf '%s\\n' \"TETHER-TTY $$\"; ps -ax -o pid= -o ppid= -o tty=; printf '%s\\n' TETHER-TTY-END"

  /// `matchSize` is false until the view has reported a size. Every new
  /// shell is 80×24 until then, which is also every other untouched client,
  /// so a size comparison would name the wrong tty.
  static func find(
    on connection: RemoteConnection, columns: UInt16, rows: UInt16, matchSize: Bool
  ) async -> String? {
    guard let listed = try? await connection.execute(listCommand),
      let text = String(data: listed.stdout, encoding: .utf8)
    else { return nil }
    let found = candidates(in: text)
    if found.count <= 1 { return found.first }
    guard matchSize, let command = sizeCommand(for: found),
      let sized = try? await connection.execute(command),
      let text = String(data: sized.stdout, encoding: .utf8)
    else { return nil }
    return choose(candidates: found, sizes: parseSizes(text), columns: columns, rows: rows)
  }

  struct Row {
    var pid: Int
    var parent: Int
    var tty: String?
  }

  /// Device paths of the other interactive sessions on this connection.
  /// Sorted, so a test can compare them. Empty when the table does not
  /// contain this command: guessing a tty from a banner is worse than none.
  static func candidates(in text: String) -> [String] {
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let start = lines.firstIndex(where: { $0.hasPrefix("TETHER-TTY ") }),
      let end = lines.firstIndex(of: "TETHER-TTY-END"),
      start < end
    else { return [] }
    let pidText = lines[start].dropFirst("TETHER-TTY ".count).trimmingCharacters(in: .whitespaces)
    guard let pid = Int(pidText) else { return [] }
    let rows = lines[lines.index(after: start)..<end].compactMap(parse)
    return devices(selfPID: pid, rows: rows)
  }

  static func parse(_ line: String) -> Row? {
    let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
    guard parts.count >= 3, let pid = Int(parts[0]), let parent = Int(parts[1]) else { return nil }
    return Row(pid: pid, parent: parent, tty: device(parts[2]))
  }

  /// The one candidate whose pty is this view. Two of the same size is not
  /// a guess: another terminal on this connection may be the same shape.
  static func choose(
    candidates: [String], sizes: [String: (columns: UInt16, rows: UInt16)], columns: UInt16,
    rows: UInt16
  ) -> String? {
    let matches = candidates.filter { sizes[$0]?.columns == columns && sizes[$0]?.rows == rows }
    return matches.count == 1 ? matches[0] : nil
  }

  static func parseSizes(_ text: String) -> [String: (columns: UInt16, rows: UInt16)] {
    var sizes: [String: (columns: UInt16, rows: UInt16)] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      // stty prints rows, then columns.
      guard parts.count == 3, isDevice(parts[0]), let rows = UInt16(parts[1]),
        let columns = UInt16(parts[2])
      else { continue }
      sizes[parts[0]] = (columns, rows)
    }
    return sizes
  }

  /// Nil unless every path is a pty name this parser would emit. The names
  /// are interpolated into a shell command, and a process table is not a
  /// place to trust a string that merely looks like a path.
  static func sizeCommand(for devices: [String]) -> String? {
    guard !devices.isEmpty, devices.allSatisfy(isDevice) else { return nil }
    let names = devices.map { "'\($0)'" }.joined(separator: " ")
    return
      "for t in \(names); do size=$(stty -F \"$t\" size 2>/dev/null || stty -f \"$t\" size 2>/dev/null) || continue; printf '%s %s\\n' \"$t\" \"$size\"; done"
  }

  static func device(_ tty: String) -> String? {
    if tty == "?" || tty == "??" || tty == "-" { return nil }
    let path = tty.hasPrefix("/") ? tty : "/dev/\(tty)"
    return isDevice(path) ? path : nil
  }

  static func isDevice(_ path: String) -> Bool {
    for prefix in ["/dev/pts/", "/dev/ttys"] {
      guard path.hasPrefix(prefix) else { continue }
      let rest = path.dropFirst(prefix.count)
      return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
    return false
  }

  private static func devices(selfPID: Int, rows: [Row]) -> [String] {
    guard rows.contains(where: { $0.pid == selfPID }) else { return [] }
    var parentOf: [Int: Int] = [:]
    var children: [Int: [Int]] = [:]
    var ttyOf: [Int: String] = [:]
    for row in rows {
      parentOf[row.pid] = row.parent
      children[row.parent, default: []].append(row.pid)
      if let tty = row.tty { ttyOf[row.pid] = tty }
    }

    var subtree: Set<Int> = [selfPID]
    var stack = [selfPID]
    while let pid = stack.popLast() {
      for child in children[pid] ?? [] where subtree.insert(child).inserted {
        stack.append(child)
      }
    }

    var ancestors: [Int] = []
    var seen: Set<Int> = []
    var cursor = selfPID
    while let parent = parentOf[cursor], seen.insert(parent).inserted, ancestors.count < 32 {
      ancestors.append(parent)
      cursor = parent
    }

    for ancestor in ancestors {
      var found: Set<String> = []
      var walked: Set<Int> = []
      var walk = [ancestor]
      while let pid = walk.popLast() {
        guard walked.insert(pid).inserted else { continue }
        if !subtree.contains(pid), let tty = ttyOf[pid] { found.insert(tty) }
        for child in children[pid] ?? [] { walk.append(child) }
      }
      if !found.isEmpty { return found.sorted() }
    }
    return []
  }
}
