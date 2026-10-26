#if os(macOS)
  import AppKit
#endif
import SwiftUI
import Tether
import TetherPluginKit

/// Native menu bar. Every item calls the same TabSet / intent dispatcher
/// the in-window palettes use; this is not a second set of buttons.
struct WorkspaceCommands: Commands {
  @Bindable var model: AppModel
  private var tabs: TabSet { model.commandTabs }
  #if os(macOS)
    private var shortcutsEnabled: Bool? { tabs.menuShortcuts }
  #else
    @FocusedValue(\.workspaceShortcutsEnabled) private var shortcutsEnabled
  #endif

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      #if os(macOS)
        Button("New Window") { model.openAdditionalWindow?() }
          .keyboardShortcut("n", modifiers: [.command, .shift])
      #endif
      command(.newTab)
      command(.renameTab)
    }
    CommandGroup(replacing: .saveItem) {
      #if os(macOS)
        // No workspace window in front — Settings, say. Replacing the
        // system's Close took ⌘W from every window, and this one still
        // closes the way any Mac window does.
        if shortcutsEnabled == nil {
          Button("Close") { NSApp.keyWindow?.performClose(nil) }
            .keyboardShortcut("w")
        } else {
          command(.closeTerminal)
          command(.closeTab)
          // With nothing open, ⌘W already reads Close Window.
          if !tabs.closesWindow { command(.closeWindow) }
        }
      #else
        command(.closeTerminal)
        command(.closeTab)
      #endif
      command(.restoreTab)
    }
    CommandGroup(after: .sidebar) {
      command(.commandMenu)
      command(.quickSwitch)
      #if os(macOS)
        command(.toggleTabBar)
        command(.inspector)
        Divider()
        command(.zen)
      #else
        // An iPad keyboard reaches the inspector here; a phone sees it
        // disabled, having no room for one.
        command(.inspector)
      #endif
    }
    CommandGroup(after: .windowArrangement) {
      #if os(macOS)
        command(.quickTerminal)
        command(.alwaysOnTop)
        Divider()
      #endif
      command(.previousTab)
      command(.nextTab)
    }
    CommandMenu("Host") {
      command(.changeHost)
      command(.manageHosts)
    }
    CommandMenu("Terminal") {
      command(.newTerminal)
      command(.renameTerminal)
      command(.reconnect)
      command(.takeOver)
      Divider()
      command(.previousTerminal)
      command(.nextTerminal)
      Divider()
      command(.splitLeft)
      command(.splitRight)
      command(.splitUp)
      command(.splitDown)
      command(.joinGroups)
    }
    CommandMenu("Plugins") {
      // One submenu per tab plugin, under its own name. The menu bar can
      // grow a menu per plugin only by knowing them in advance, which is
      // exactly what the host must not do.
      if let tab = tabs.current, !tabs.accessories.isEmpty {
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
    #if os(macOS)
      // The components are credits, not menu items: rows a person cannot
      // choose do not belong in a menu.
      CommandGroup(replacing: .appInfo) {
        Button("About Tether") { AboutPanel.show() }
      }
      CommandGroup(replacing: .help) {
        KeyboardShortcutsHelp()
      }
    #endif
  }

  private func command(_ action: WorkspaceAction) -> some View {
    Button(tabs.title(for: action)) { tabs.perform(action) }
      .disabled(!tabs.canPerform(action))
      .keyboardShortcut(tabs.menuShortcut(for: action)?.keyboardShortcut)
      .disabled(shortcutsEnabled != true)
  }
}

#if os(macOS)
  /// The standard About panel, with what Tether is composed of as its credits.
  @MainActor
  enum AboutPanel {
    static func show() {
      let credits = NSAttributedString(
        string: Tether.composition().joined(separator: "\n"),
        attributes: [
          .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
          .foregroundColor: NSColor.secondaryLabelColor,
        ])
      NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
  }

  /// Help ▸ Keyboard Shortcuts: the Key Bindings settings, where every
  /// shortcut is listed and can be changed. One table, not a second copy.
  private struct KeyboardShortcutsHelp: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
      Button("Keyboard Shortcuts") {
        SettingsSectionPreference.show(.keyBindings)
        openSettings()
      }
    }
  }
#endif

private struct PluginShortcut: ViewModifier {
  let tabs: TabSet
  let id: String
  #if os(macOS)
    private var enabled: Bool? { tabs.menuShortcuts }
  #else
    @FocusedValue(\.workspaceShortcutsEnabled) private var enabled
  #endif
  func body(content: Content) -> some View {
    content
      .keyboardShortcut(tabs.keyBindings.bindings(forID: id).compactMap { $0 }.first?.keyboardShortcut)
      .disabled(enabled != true)
  }
}
