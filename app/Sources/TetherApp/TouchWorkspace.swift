import Foundation

/// What a touch screen shows of the workspace, decided here rather than in
/// the view so a Mac test run can check it: the phone and the iPad draw
/// their chrome from these lists and nothing else.

extension WorkspaceAction {
  /// Actions that put a second column beside the terminal. They need a
  /// window wide enough to hold it, which a phone never is.
  var needsWidth: Bool {
    switch self {
    case .inspector, .splitLeft, .splitRight, .splitUp, .splitDown, .joinGroups: true
    default: false
    }
  }
}

/// The Commands menu on a touch screen.
///
/// Not the Mac's menu bar laid flat: only what applies to the terminal in
/// front, in short sections. What the screen already shows as a control —
/// back to the hosts, the inspector button, the terminal list under the
/// title — is not repeated here, and neither is anything
/// that only makes sense with a keyboard (the palettes, cycling tabs). Those
/// stay bound to their shortcuts through the scene's commands. On a phone
/// the menu also carries what its bar has no room for — the plugins'
/// buttons and Close — which the view adds around these sections.
enum TouchCommands {
  static func sections(wide: Bool) -> [[WorkspaceAction]] {
    var sections: [[WorkspaceAction]] = [[.renameTerminal, .reconnect], [.manageHosts]]
    if wide {
      sections.append([.splitLeft, .splitRight, .splitUp, .splitDown])
      sections.append([.joinGroups])
    }
    return sections
  }
}

/// One thing the title menu can switch to.
struct TerminalChoice: Identifiable, Equatable {
  let id: UUID
  let title: String
  let current: Bool
}

/// The choices on one host, under that host's name.
struct TerminalChoiceGroup: Identifiable, Equatable {
  /// The host's ID; `nil` for plugin workspaces that belong to no host.
  let id: UUID?
  let title: String
  let choices: [TerminalChoice]
}

extension TabSet {
  /// Everything open, by host, for a screen that shows one at a time.
  ///
  /// Every host rather than the current one: on a phone, tapping a host
  /// opens a new terminal, so this list is the only way back to one already
  /// running somewhere else. Hosts keep the order their first terminal was
  /// opened in, so the list does not reshuffle as the person moves around.
  var terminalChoices: [TerminalChoiceGroup] {
    var order: [UUID?] = []
    var titles: [UUID?: String] = [:]
    var choices: [UUID?: [TerminalChoice]] = [:]
    func add(_ choice: TerminalChoice, host: UUID?, title: String) {
      if choices[host] == nil {
        order.append(host)
        titles[host] = title
      }
      choices[host, default: []].append(choice)
    }
    for tab in tabs {
      add(TerminalChoice(id: tab.id, title: terminalMenuTitle(tab), current: tab.id == selected),
        host: tab.host.id, title: tab.host.displayName)
    }
    for entry in extensions {
      let host = entry.hostID.flatMap { id in tabs.first { $0.host.id == id }?.host }
      add(TerminalChoice(id: entry.id, title: entry.workspace.title, current: entry.id == selected),
        host: entry.hostID, title: host?.displayName ?? "")
    }
    return order.map { TerminalChoiceGroup(id: $0, title: titles[$0] ?? "", choices: choices[$0] ?? []) }
  }
}
