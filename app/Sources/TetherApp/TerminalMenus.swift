import Foundation
import TetherUI

extension TabSet {
  var pendingCloseVerb: String { closingWorkspaceID != nil ? "Close Tab" : "Close Terminal" }

  func terminalMenuTitle(_ terminal: SessionTab) -> String {
    "\(displayTitle(for: terminal.id)) — \(terminal.stateName)"
  }

  func terminalMenu(for id: UUID) -> [TerminalMenuItem] {
    guard let page = workspace(containing: id) else { return [] }
    let choices = page.terminalIDs.compactMap { terminalID -> TerminalMenuItem? in
      guard let terminal = tabs.first(where: { $0.id == terminalID }) else { return nil }
      return TerminalMenuItem(terminalMenuTitle(terminal), checked: terminalID == page.focused) { [weak self] in
        self?.select(terminalID)
      }
    }
    func item(_ action: WorkspaceAction, enabled: Bool = true) -> TerminalMenuItem {
      TerminalMenuItem(title(for: action), enabled: enabled) { [weak self] in
        guard let self, self.tabs.contains(where: { $0.id == id }) else { return }
        self.select(id)
        self.perform(action)
      }
    }
    let source = tabs.first { $0.id == id }
    let canSplit = source.map { $0.isLive || $0.host.isLocal } ?? false
    var result = [TerminalMenuItem("Switch Terminal", children: choices), .separator,
      item(.newTerminal), item(.newTab)]
    #if os(macOS)
      result += [item(.splitLeft, enabled: canSplit), item(.splitRight, enabled: canSplit),
        item(.splitUp, enabled: canSplit), item(.splitDown, enabled: canSplit),
        item(.joinGroups, enabled: page.layout != nil)]
    #endif
    result += [.separator, item(.renameTerminal), item(.closeTerminal)]
    return result
  }
}
