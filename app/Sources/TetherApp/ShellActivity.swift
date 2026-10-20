import Foundation
import Tether

/// Work that closing a terminal could interrupt. A waiting login shell is idle.
enum ShellActivity: Equatable, Sendable {
  case idle
  case running([String])
  case unknown

  /// The one line a close confirmation adds: what may stop. "May", because
  /// a process can outlive its terminal; and when nothing could be checked,
  /// nothing is claimed about what is running.
  var closeMessage: String? {
    switch self {
    case .idle: nil
    case .running(let names):
      "\(ListFormatter.localizedString(byJoining: names)) may stop."
    case .unknown:
      "Anything running here may stop."
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

/// Keeps the close check ahead of the close gesture.
///
/// What runs on a shell's terminal changes only through that terminal:
/// something typed, something printed, a resize. A check begun after the
/// last of those still describes the shell, so once the terminal has been
/// quiet for a moment the check runs ahead, and ⌘W on an idle tab need not
/// wait for a process listing — two seconds when the network is slow.
///
/// Only *idle* is kept. Work can finish without a word (a background job
/// prints nothing until the next prompt), so a remembered "running" could be
/// stale; it cannot start without one, so a remembered "idle" cannot. Any
/// other answer, or one begun before the latest activity, is checked again
/// at the close, as before.
@MainActor
final class CloseCheck {
  /// How long the terminal stays quiet before the check runs ahead.
  static let quiet: Duration = .seconds(2)

  private let check: @MainActor () async -> ShellActivity
  private let quiet: Duration
  /// Bumped by every typed key, printed byte and resize.
  private(set) var epoch = 0
  private var answer: (epoch: Int, task: Task<ShellActivity, Never>, result: ShellActivity?)?
  private var waiting: Task<Void, Never>?

  init(quiet: Duration = CloseCheck.quiet, check: @escaping @MainActor () async -> ShellActivity) {
    self.quiet = quiet
    self.check = check
  }

  /// Something was typed, printed or resized. Earlier answers no longer
  /// hold, and a new one is taken once the terminal is quiet again.
  func noteActivity() {
    epoch += 1
    guard waiting == nil else { return }
    let quiet = quiet
    waiting = Task { [weak self] in
      while true {
        guard let seen = self?.epoch else { return }
        do { try await Task.sleep(for: quiet) } catch { return }
        guard let self else { return }
        if self.epoch == seen { break }
      }
      self?.waiting = nil
      self?.start()
    }
  }

  /// What closing could interrupt now.
  func activity() async -> ShellActivity {
    if let answer, answer.epoch == epoch {
      // Still running: begun after the latest activity, it is as good as
      // one begun now.
      guard let result = answer.result else { return await answer.task.value }
      if result == .idle { return .idle }
    }
    return await start(fresh: true).value
  }

  /// A new session, or none: nothing known about the old one holds.
  func reset() {
    epoch += 1
    answer = nil
    waiting?.cancel()
    waiting = nil
  }

  @discardableResult
  private func start(fresh: Bool = false) -> Task<ShellActivity, Never> {
    if !fresh, let answer, answer.epoch == epoch { return answer.task }
    let epoch = epoch
    let check = check
    let task = Task { await check() }
    answer = (epoch, task, nil)
    Task { [weak self] in
      let result = await task.value
      guard let self, self.answer?.epoch == epoch, self.answer?.task == task else { return }
      self.answer?.result = result
    }
    return task
  }
}
