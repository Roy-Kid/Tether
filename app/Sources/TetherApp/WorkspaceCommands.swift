import SwiftUI
import Tether
import TetherPluginKit

/// Native menu bar. Every item calls the same TabSet / intent dispatcher
/// the in-window palettes use; this is not a second set of buttons.
struct WorkspaceCommands: Commands {
  @Bindable var tabs: TabSet

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Terminal") { tabs.intent = .newTerminal }
        .keyboardShortcut("n")
      Button("Change Host…") { tabs.hostPicker = true }
        .keyboardShortcut("h", modifiers: [.command, .shift])
    }
    CommandGroup(replacing: .saveItem) {
      Button("Close Tab") { tabs.requestCloseSelected() }
        .keyboardShortcut("w")
        .disabled(tabs.selected == nil && tabs.palette == nil && !tabs.hostPicker)
    }
    CommandGroup(after: .sidebar) {
      Button("Command Menu") { tabs.openPalette(.command) }
        .keyboardShortcut("p", modifiers: [.command, .shift])
      Button("Quick Switch…") { tabs.openPalette(.quickSwitch) }
        .keyboardShortcut("p")
      Button("Inspector") { tabs.toggleInspector() }
        .disabled(tabs.zen)
      Divider()
      Button(tabs.zen ? "Exit Zen Mode" : "Zen Mode") { tabs.toggleZen() }
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }
    CommandGroup(after: .windowArrangement) {
      Button("Previous Tab") { tabs.cycleTab(forward: false) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(tabs.visibleIDs.isEmpty)
      Button("Next Tab") { tabs.cycleTab(forward: true) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(tabs.visibleIDs.isEmpty)
    }
    CommandMenu("Terminal") {
      Button("Rename Terminal…") { tabs.renaming = tabs.current?.id }
        .disabled(tabs.current == nil)
      Button("New Terminal") { tabs.intent = .newTerminal }
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
            .disabled(!tab.canOpen(plugin.id))
            if let commands = tab.attachment(for: plugin.id)?.commands, !commands.isEmpty {
              Divider()
              ForEach(commands) { command in
                Button(command.title, action: command.action)
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
}
