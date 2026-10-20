import TetherPluginKit

enum WorkspaceAction: String, CaseIterable {
  case newTab, closeTerminal, previousTerminal, nextTerminal, renameTab
  case newTerminal, changeHost, closeTab, closeWindow, commandMenu, quickSwitch, inspector, zen
  case previousTab, nextTab, renameTerminal, manageHosts
  case toggleTabBar
  case restoreTab
  case splitLeft, splitRight, splitUp, splitDown, joinGroups
  case reconnect
  case quickTerminal, restoreWindow, alwaysOnTop

  /// The tab bar, zen and closing the window belong to a Mac window. The inspector and splits
  /// are here everywhere, and `TabSet.canPerform` keeps them to a window
  /// wide enough for them — an iPad, not a phone.
  static var available: [Self] {
    #if os(macOS)
      allCases
    #else
      allCases.filter { $0 != .toggleTabBar && $0 != .zen && $0 != .closeWindow && $0 != .quickTerminal && $0 != .restoreWindow && $0 != .alwaysOnTop }
    #endif
  }

  var command: KeyBindingCommand {
    // Command shortcuts leave Unix Control/Meta editing keys available to
    // the terminal unless the user explicitly assigns them.
    //
    // Closing goes terminal, tab, window as the modifiers grow — ⌘W, ⌥⌘W,
    // ⇧⌘W — the way terminals with splits do it, so the commonest close
    // takes the least. A tab holding one terminal goes with it either way.
    switch self {
    case .newTerminal: definition("New Terminal", "Terminal", KeyBinding("n"))
    case .newTab: definition("New Tab", "File", KeyBinding("t"))
    case .closeTerminal: definition("Close Terminal", "File", KeyBinding("w"))
    case .previousTerminal: definition("Previous Terminal", "Terminal", KeyBinding("up", [.command, .option]))
    case .nextTerminal: definition("Next Terminal", "Terminal", KeyBinding("down", [.command, .option]))
    case .renameTab: definition("Rename Tab…", "File")
    case .changeHost: definition("Change Host…", "Host", KeyBinding("h", [.command, .shift]))
    case .closeTab: definition("Close Tab", "File", KeyBinding("w", [.command, .option]))
    case .closeWindow: definition("Close Window", "File", KeyBinding("w", [.command, .shift]))
    case .restoreTab: definition("Reopen Closed Tab", "File", KeyBinding("t", [.command, .shift]))
    case .commandMenu:
      definition("Command Palette", "View", KeyBinding("p", [.command, .shift]), KeyBinding("p", [.control, .shift]))
    case .quickTerminal: definition("Toggle Quick Terminal", "Window", KeyBinding("`", .control))
    case .restoreWindow: definition("Return to Normal Window", "Window")
    case .alwaysOnTop: definition("Keep Window on Top", "Window")
    case .quickSwitch: definition("Quick Switch…", "View", KeyBinding("p"))
    case .inspector: definition("Inspector", "View")
    // No default: ⌘S is Save on a Mac, and hiding the strip is rare.
    case .toggleTabBar: definition("Toggle Tab Bar", "View")
    case .zen: definition("Zen Mode", "View", KeyBinding("z", [.command, .shift]))
    // ⇧⌘[ and ⇧⌘] are what Safari, Terminal and most tabbed Mac apps use.
    case .previousTab:
      definition("Previous Tab", "Window", KeyBinding("left", [.command, .option]), KeyBinding("[", [.command, .shift]))
    case .nextTab:
      definition("Next Tab", "Window", KeyBinding("right", [.command, .option]), KeyBinding("]", [.command, .shift]))
    case .renameTerminal: definition("Rename Terminal…", "Terminal", KeyBinding("r"))
    case .manageHosts: definition("Manage Hosts…", "Host")
    case .splitLeft: definition("Split Left", "Terminal")
    case .splitUp: definition("Split Up", "Terminal")
    case .splitRight: definition("Split Right", "Terminal", KeyBinding("\\"))
    case .splitDown: definition("Split Down", "Terminal", KeyBinding("\\", [.command, .shift]))
    case .joinGroups: definition("Join All Splits", "Terminal")
    case .reconnect: definition("Reconnect", "Terminal")
    }
  }

  /// The commands a chord still reaches while a text field is being edited.
  /// The palettes are opened, swapped and closed from inside their own
  /// search fields, and no field gives these chords a meaning. Every other
  /// chord goes the way it goes in any Mac text field — the field and the
  /// Edit menu first — so ⇧⌘Z there is Redo, not Zen (spec §4).
  static func answersWhileEditingText(_ id: String) -> Bool {
    switch Self(rawValue: id) {
    case .commandMenu, .quickSwitch, .closeTerminal, .closeTab, .closeWindow: true
    default: false
    }
  }

  private func definition(_ title: String, _ group: String,
                          _ primary: KeyBinding? = nil, _ secondary: KeyBinding? = nil) -> KeyBindingCommand {
    KeyBindingCommand(id: rawValue, title: title, group: group, defaults: [primary, secondary])
  }
}

extension KeyBinding {
  init(_ chord: PluginKeyChord) {
    var modifiers: KeyModifiers = []
    if chord.modifiers.contains(.control) { modifiers.insert(.control) }
    if chord.modifiers.contains(.option) { modifiers.insert(.option) }
    if chord.modifiers.contains(.shift) { modifiers.insert(.shift) }
    if chord.modifiers.contains(.command) { modifiers.insert(.command) }
    self.init(chord.key, modifiers)
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
        KeyBindingCommand(id: commandID($0.id, plugin: metadata.id), title: $0.title, group: metadata.name,
                          defaults: [$0.shortcut.map(KeyBinding.init).flatMap { $0.isValid ? $0 : nil }, nil],
                          layer: .attachment)
      }
      // Also discover commands from third-party plugins without a static catalogue.
      let active = tabs?.current?.attachment(for: metadata.id)?.commands ?? []
      let workspaces = tabs?.extensions.filter { $0.pluginID == metadata.id }.flatMap { $0.workspace.commands } ?? []
      for command in active + workspaces {
        let id = commandID(command.id, plugin: metadata.id)
        if !result.contains(where: { $0.id == id }) {
          result.append(KeyBindingCommand(id: id, title: command.title, group: metadata.name, layer: .attachment))
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
    case .reconnect: current?.host.isLocal == true ? "Restart" : action.command.title
    case .alwaysOnTop:
      #if os(macOS)
        quickTerminal.alwaysOnTop ? "Stop Keeping Window on Top" : action.command.title
      #else
        action.command.title
      #endif
    case .closeTerminal: closesWindow ? "Close Window" : action.command.title
    default: action.command.title
    }
  }

  /// The plugin commands the window offers now, by binding id: those of the
  /// attachments on the terminal in front, or of the plugin page selected.
  /// While one holds a chord, the chord is its (`KeyBindingStore.command`).
  var offeredCommandIDs: Set<String> {
    if let entry = extensions.first(where: { $0.id == selected }) {
      return Set(entry.workspace.commands.map { KeyBindingCatalog.commandID($0.id, plugin: entry.pluginID) })
    }
    let attachments = current?.attachments ?? []
    return Set(attachments.flatMap { entry in
      entry.attachment.commands.map { KeyBindingCatalog.commandID($0.id, plugin: entry.pluginID) }
    })
  }

  /// The chord the menu bar shows for one of the window's commands. A chord
  /// an offered plugin command holds is that command's for now, and two menu
  /// items must not claim one key.
  func menuShortcut(for action: WorkspaceAction) -> KeyBinding? {
    let taken = offeredCommandIDs.flatMap { keyBindings.bindings(forID: $0).compactMap { $0 } }
    return keyBindings.bindings(for: action.command).compactMap { $0 }.first { !taken.contains($0) }
  }

  /// Something open in the window that ⌘W would close before the terminal under it.
  private var hasSomethingToClose: Bool {
    selected != nil || palette != nil || hostPicker || accessory != nil || tabMenu != nil
  }

  /// Close Terminal when the window holds nothing it could close. On a Mac that is
  /// still a shortcut with a meaning — the window — rather than a beep.
  var closesWindow: Bool {
    #if os(macOS)
      !hasSomethingToClose
    #else
      false
    #endif
  }

  func canPerform(_ action: WorkspaceAction) -> Bool {
    switch action {
    case .closeTerminal: hasSomethingToClose || closesWindow
    case .closeTab: hasSomethingToClose
    case .quickTerminal:
      #if os(macOS)
        quickTerminal.enabled
      #else
        false
      #endif
    case .restoreWindow:
      #if os(macOS)
        quickTerminal.isQuick
      #else
        false
      #endif
    case .alwaysOnTop:
      #if os(macOS)
        true
      #else
        false
      #endif
    case .restoreTab: canRestoreTab
    case .renameTerminal: current != nil
    case .renameTab: currentWorkspace != nil
    case .previousTerminal, .nextTerminal: currentTerminals.count > 1
    case .splitLeft, .splitRight, .splitUp, .splitDown:
      wide && (current.map { $0.isLive || $0.host.isLocal } ?? false)
    case .joinGroups: workspaceSplit != nil
    case .reconnect: current?.canReconnect == true
    case .inspector: !zen && wide
    case .previousTab, .nextTab: !visibleIDs.isEmpty
    default: true
    }
  }

  func perform(_ action: WorkspaceAction) {
    guard canPerform(action) else { return }
    switch action {
    case .quickTerminal:
      #if os(macOS)
        quickTerminal.toggle()
      #endif
    case .restoreWindow:
      #if os(macOS)
        quickTerminal.restore()
      #endif
    case .alwaysOnTop:
      #if os(macOS)
        quickTerminal.alwaysOnTop.toggle()
      #endif
    case .newTerminal: intent = currentWorkspace.map { .addTerminal($0.id) } ?? .newTerminal
    case .newTab: intent = .newTab
    case .closeTerminal: requestCloseFocused()
    case .previousTerminal: cycleTerminal(forward: false)
    case .nextTerminal: cycleTerminal(forward: true)
    case .renameTab: renamingWorkspace = currentWorkspace?.id
    case .changeHost: hostPicker = true
    case .closeTab: requestCloseSelected()
    case .closeWindow: requestWindowClose()
    case .restoreTab: requestRestoreTab()
    case .commandMenu: openPalette(.command)
    case .quickSwitch: openPalette(.quickSwitch)
    case .inspector: toggleInspector()
    case .toggleTabBar: toggleTabBar()
    case .zen: toggleZen()
    case .previousTab: cycleTab(forward: false)
    case .nextTab: cycleTab(forward: true)
    case .renameTerminal: renaming = current?.id
    case .manageHosts: SettingsRoute.shared.show()
    case .splitLeft:
      if let id = current?.id { intent = .splitTerminal(id, .left) }
    case .splitUp:
      if let id = current?.id { intent = .splitTerminal(id, .up) }
    case .splitRight:
      if let id = current?.id { intent = .splitTerminal(id, .right) }
    case .splitDown:
      if let id = current?.id { intent = .splitTerminal(id, .down) }
    case .joinGroups: joinSplits()
    case .reconnect: if let id = current?.id { intent = .reconnect(id) }
    }
  }
}
