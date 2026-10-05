import TetherPluginKit

enum WorkspaceAction: String, CaseIterable {
  case newTerminal, changeHost, closeTab, commandMenu, quickSwitch, inspector, zen
  case previousTab, nextTab, renameTerminal, manageHosts
  case toggleTabBar
  case restoreTab

  static var available: [Self] {
    #if os(macOS)
      allCases
    #else
      allCases.filter { $0 != .inspector && $0 != .toggleTabBar }
    #endif
  }

  var command: KeyBindingCommand {
    // Command shortcuts leave Unix Control/Meta editing keys available to
    // the terminal unless the user explicitly assigns them.
    switch self {
    case .newTerminal: definition("New Terminal", "File", KeyBinding("n"), KeyBinding("t"))
    case .changeHost: definition("Change Host…", "File", KeyBinding("h", [.command, .shift]))
    case .closeTab: definition("Close Tab", "File", KeyBinding("w"))
    case .restoreTab: definition("Restore Tab", "File", KeyBinding("t", [.command, .shift]))
    case .commandMenu:
      definition("Command Menu", "View", KeyBinding("p", [.command, .shift]), KeyBinding("p", [.control, .shift]))
    case .quickSwitch: definition("Quick Switch…", "View", KeyBinding("p"))
    case .inspector: definition("Inspector", "View")
    case .toggleTabBar: definition("Toggle Tab Bar", "View", KeyBinding("s"))
    case .zen: definition("Zen Mode", "View", KeyBinding("z", [.command, .shift]))
    case .previousTab: definition("Previous Tab", "Window", KeyBinding("left", [.command, .option]))
    case .nextTab: definition("Next Tab", "Window", KeyBinding("right", [.command, .option]))
    case .renameTerminal: definition("Rename Terminal…", "Terminal", KeyBinding("r"))
    case .manageHosts: definition("Manage Hosts…", "File")
    }
  }

  private func definition(_ title: String, _ group: String,
                          _ primary: KeyBinding? = nil, _ secondary: KeyBinding? = nil) -> KeyBindingCommand {
    KeyBindingCommand(id: rawValue, title: title, group: group, defaults: [primary, secondary])
  }
}

@MainActor
enum KeyBindingCatalog {
  static func launchID(_ plugin: String) -> String { "plugin.\(plugin).launch" }
  static func commandID(_ command: String, plugin: String) -> String { "plugin.\(plugin).command.\(command)" }

  static func commands(registry: PluginRegistry, tabs: TabSet? = nil) -> [KeyBindingCommand] {
    var result = WorkspaceAction.available.map(\.command)
    for plugin in registry.plugins {
      let metadata = plugin.metadata
      if !plugin.isStatusBarOnly {
        result.append(KeyBindingCommand(id: launchID(metadata.id), title: "Open \(metadata.name)", group: metadata.name))
      }
      result += plugin.commandDescriptors.map {
        KeyBindingCommand(id: commandID($0.id, plugin: metadata.id), title: $0.title, group: metadata.name)
      }
      // Also discover commands from third-party plugins without a static catalogue.
      let active = tabs?.current?.attachment(for: metadata.id)?.commands ?? []
      let workspaces = tabs?.extensions.filter { $0.pluginID == metadata.id }.flatMap { $0.workspace.commands } ?? []
      for command in active + workspaces {
        let id = commandID(command.id, plugin: metadata.id)
        if !result.contains(where: { $0.id == id }) {
          result.append(KeyBindingCommand(id: id, title: command.title, group: metadata.name))
        }
      }
    }
    return result
  }
}

extension TabSet {
  func title(for action: WorkspaceAction) -> String {
    switch action {
    case .zen: zen ? "Exit Zen Mode" : action.command.title
    case .toggleTabBar: showsTabBar ? "Hide Tab Bar" : "Show Tab Bar"
    default: action.command.title
    }
  }

  func canPerform(_ action: WorkspaceAction) -> Bool {
    switch action {
    case .closeTab: selected != nil || palette != nil || hostPicker || accessory != nil || tabMenu != nil
    case .restoreTab: canRestoreTab
    case .renameTerminal: current != nil
    case .inspector: !zen
    case .previousTab, .nextTab: !visibleIDs.isEmpty
    default: true
    }
  }

  func perform(_ action: WorkspaceAction) {
    guard canPerform(action) else { return }
    switch action {
    case .newTerminal: intent = .newTerminal
    case .changeHost: hostPicker = true
    case .closeTab: requestCloseSelected()
    case .restoreTab: requestRestoreTab()
    case .commandMenu: openPalette(.command)
    case .quickSwitch: openPalette(.quickSwitch)
    case .inspector: toggleInspector()
    case .toggleTabBar: toggleTabBar()
    case .zen: toggleZen()
    case .previousTab: cycleTab(forward: false)
    case .nextTab: cycleTab(forward: true)
    case .renameTerminal: renaming = current?.id
    case .manageHosts: manageHosts = true
    }
  }
}
