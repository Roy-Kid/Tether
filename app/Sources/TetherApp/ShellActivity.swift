import Foundation
import Tether

/// Work that closing a terminal could interrupt. A waiting login shell is idle.
enum ShellActivity: Equatable, Sendable {
  case idle
  case running([String])
  case unknown

  var closeMessage: String? {
    switch self {
    case .idle: nil
    case .running(let names):
      "Processes are still running in this tab: \(names.joined(separator: ", ")). Closing the tab may terminate them and lose unsaved work."
    case .unknown:
      "Unable to check for running processes in this tab. Closing it may terminate processes and lose unsaved work."
    }
  }

  // Framing excludes login banners. `comm` avoids exposing command arguments.
  static let listCommand =
    "printf '%s\\n' TETHER-PROCESSES; LC_ALL=C ps -ax -o pid= -o ppid= -o tty= -o stat= -o comm= && printf '%s\\n' TETHER-PROCESSES-END"

  static func check(
    on connection: RemoteConnection, terminal: String?, columns: UInt16, rows: UInt16,
    matchSize: Bool
  ) async -> ShellActivity {
    // A lost SSH connection must not leave the close gesture waiting indefinitely.
    await withTaskGroup(of: ShellActivity.self) { group in
      group.addTask {
        let tty: String?
        if let terminal { tty = terminal }
        else {
          tty = await ShellTTY.find(
            on: connection, columns: columns, rows: rows, matchSize: matchSize)
        }
        guard !Task.isCancelled, let tty,
          let output = try? await connection.execute(listCommand), output.status == 0,
          let text = String(data: output.stdout, encoding: .utf8)
        else { return .unknown }
        return parse(text, terminal: tty)
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return .unknown
      }
      let result = await group.next() ?? .unknown
      group.cancelAll()
      return result
    }
  }

  private struct ProcessRow {
    let pid: Int
    let parent: Int
    let tty: String?
    let state: String
    let name: String

    init?(_ line: Substring) {
      let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
      guard parts.count == 5, let pid = Int(parts[0]), let parent = Int(parts[1]) else {
        return nil
      }
      self.pid = pid
      self.parent = parent
      tty = ShellTTY.device(String(parts[2]))
      state = String(parts[3])
      let command = parts[4].trimmingCharacters(in: .whitespaces)
      name = String(command.split(separator: "/").last ?? Substring(command))
    }
  }

  static func parse(_ text: String, terminal: String) -> ShellActivity {
    let lines = text.split(whereSeparator: \.isNewline)
    guard ShellTTY.isDevice(terminal),
      let start = lines.firstIndex(of: "TETHER-PROCESSES"),
      let end = lines.firstIndex(of: "TETHER-PROCESSES-END"), start < end
    else { return .unknown }
    let body = lines[lines.index(after: start)..<end]
    let processes = body.compactMap(ProcessRow.init)
    // An incomplete/unsupported process table cannot prove the tab is idle.
    guard processes.count == body.count else { return .unknown }
    let onTTY = processes.filter { $0.tty == terminal }
    guard !onTTY.isEmpty else { return .unknown }
    let ttyPIDs = Set(onTTY.map(\.pid))
    let roots = onTTY.filter { !ttyPIDs.contains($0.parent) }
    guard roots.count == 1, let shell = roots.first else { return .unknown }

    var children: [Int: [Int]] = [:]
    for row in processes { children[row.parent, default: []].append(row.pid) }
    var owned = ttyPIDs
    var stack = Array(owned)
    while let pid = stack.popLast() {
      for child in children[pid] ?? [] where owned.insert(child).inserted { stack.append(child) }
    }
    let shells: Set<String> = [
      "sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "ksh93", "mksh", "csh", "tcsh",
      "nu", "elvish", "xonsh",
    ]
    let running = processes.filter { row in
      guard owned.contains(row.pid), !row.state.hasPrefix("Z"), !row.state.hasPrefix("X") else {
        return false
      }
      // Only the root shell can be ignored. Nested shells, background jobs
      // and stopped jobs still belong to the tab, even without a foreground job.
      let waitingShell = row.pid == shell.pid
        && shells.contains(String(row.name.drop(while: { $0 == "-" })))
        && (row.state.hasPrefix("S") || row.state.hasPrefix("I"))
      return !waitingShell
    }
    return running.isEmpty ? .idle : .running(Array(Set(running.map(\.name))).sorted())
  }
}
