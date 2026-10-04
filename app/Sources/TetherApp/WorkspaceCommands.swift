import SwiftUI
import Tether
import TetherPluginKit

/// Native menu bar. Every item calls the same TabSet / intent dispatcher
/// the in-window palettes use; this is not a second set of buttons.
struct WorkspaceCommands: Commands {
  @Bindable var tabs: TabSet
  #if os(macOS)
    @FocusedValue(\.workspaceShortcutsEnabled) private var shortcutsEnabled
  #endif

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      command(.newTerminal)
      command(.changeHost)
      command(.manageHosts)
    }
    CommandGroup(replacing: .saveItem) {
      command(.closeTab)
    }
    CommandGroup(after: .sidebar) {
      command(.commandMenu)
      command(.quickSwitch)
      #if os(macOS)
        command(.toggleTabBar)
      #endif
      command(.inspector)
      Divider()
      command(.zen)
    }
    CommandGroup(after: .windowArrangement) {
      command(.previousTab)
      command(.nextTab)
    }
    CommandMenu("Terminal") {
      command(.renameTerminal)
      command(.newTerminal)
      // One submenu per tab plugin, under its own name. The menu bar can
      // grow a menu per plugin only by knowing them in advance, which is
      // exactly what the host must not do.
      if let tab = tabs.current, !tabs.accessories.isEmpty {
        Divider()
        ForEach(tabs.accessories) { plugin in
          Menu(plugin.title) {
            Button("\(plugin.accessory.name.localizedCapitalized)…") {
              tabs.toggleAccessory(plugin.id, on: tab.id)
            }
            .modifier(PluginShortcut(tabs: tabs, id: KeyBindingCatalog.launchID(plugin.id)))
            .disabled(!tab.canOpen(plugin.id))
            if let commands = tab.attachment(for: plugin.id)?.commands, !commands.isEmpty {
              Divider()
              ForEach(commands) { command in
                Button(command.title, action: command.action)
                  .modifier(PluginShortcut(tabs: tabs, id: KeyBindingCatalog.commandID(command.id, plugin: plugin.id)))
              }
            }
          }
        }
      }
    }
    CommandGroup(after: .appInfo) {
      ForEach(Tether.composition(), id: \.self) { part in
        Text(part)
      }
    }
  }

  private func command(_ action: WorkspaceAction) -> some View {
    Button(tabs.title(for: action)) { tabs.perform(action) }
      .disabled(!tabs.canPerform(action))
      #if os(macOS)
        .keyboardShortcut(tabs.keyBindings.bindings(for: action.command).compactMap { $0 }.first?.keyboardShortcut)
        .disabled(shortcutsEnabled != true)
      #endif
  }
}

private struct PluginShortcut: ViewModifier {
  let tabs: TabSet
  let id: String
  #if os(macOS)
    @FocusedValue(\.workspaceShortcutsEnabled) private var enabled
  #endif
  func body(content: Content) -> some View {
    content
      #if os(macOS)
        .keyboardShortcut(tabs.keyBindings.bindings(for: KeyBindingCommand(id: id, title: id, group: ""))
          .compactMap { $0 }.first?.keyboardShortcut)
        .disabled(enabled != true)
      #endif
  }
}
