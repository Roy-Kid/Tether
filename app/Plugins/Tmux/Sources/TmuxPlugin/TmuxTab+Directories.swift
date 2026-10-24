import Tether
import TetherPluginKit

extension TmuxTab {
  /// The directory of the pane that shows `link`, found without this tab's tty.
  ///
  /// Every attached session's current window is a candidate. The pane under
  /// the link is read back from tmux, and only one that has the link's text
  /// on that row counts. Two sessions laid out alike can both have a pane
  /// there; the text is what tells them apart. When the panes that show it
  /// disagree on a directory, there is no answer — a wrong directory would
  /// open a different file of the same name.
  func directory(showing link: TerminalLink, on connection: RemoteConnection) async -> String? {
    guard let span = link.spans.first,
      let fragment = TmuxPaneSearch.fragment(of: link),
      let sessions = try? await connection.tmuxSessions()
    else { return nil }
    var found: Set<String> = []
    for session in sessions where session.attached {
      guard !closed, !Task.isCancelled, self.connection?.leaseID() == connection.leaseID(),
        let command = TmuxPaneDirectories.listCommand(session: session.id),
        let listed = try? await connection.execute(command), listed.status == 0,
        let text = String(data: listed.stdout, encoding: .utf8),
        let entries = TmuxPaneDirectories.parse(text),
        let cell = TmuxPaneSearch.cell(in: entries, column: Int(span.start), row: Int(span.row)),
        let capture = TmuxPaneSearch.captureCommand(pane: cell.entry.pane.id, row: cell.row),
        let captured = try? await connection.execute(capture), captured.status == 0,
        let line = String(data: captured.stdout, encoding: .utf8),
        line.contains(fragment)
      else { continue }
      found.insert(cell.entry.directory)
    }
    guard !closed, !Task.isCancelled, self.connection?.leaseID() == connection.leaseID() else { return nil }
    return found.count == 1 ? found.first : nil
  }
}

/// Finding a pane by what it shows.
enum TmuxPaneSearch {
  /// The part of a link drawn on its first row: what a pane's line must
  /// contain for that pane to be the one showing it.
  static func fragment(of link: TerminalLink) -> String? {
    guard let span = link.spans.first, span.end > span.start else { return nil }
    let fragment = String(link.text.prefix(Int(span.end - span.start)))
    return fragment.isEmpty ? nil : fragment
  }

  /// The pane under a terminal cell, and that cell's row inside the pane.
  static func cell(
    in entries: [TmuxPaneDirectories.Entry], column: Int, row: Int
  ) -> (entry: TmuxPaneDirectories.Entry, row: Int)? {
    guard let pane = TmuxPaneLayout.pane(in: entries.map(\.pane), column: column, row: row),
      let entry = entries.first(where: { $0.pane.id == pane.id })
    else { return nil }
    let statusOffset = pane.statusTop ? pane.statusLines : 0
    return (entry, row - statusOffset - pane.top)
  }

  /// One visible line of a pane. The id is quoted as well as checked: it
  /// came from the far side.
  static func captureCommand(pane: String, row: Int) -> String? {
    guard pane.count > 1, pane.count <= 20, pane.first == "%",
      pane.dropFirst().allSatisfy({ $0 >= "0" && $0 <= "9" }), row >= 0
    else { return nil }
    return "tmux capture-pane -p -t '\(pane)' -S \(row) -E \(row)"
  }
}
