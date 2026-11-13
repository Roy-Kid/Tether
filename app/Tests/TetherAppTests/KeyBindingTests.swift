import Foundation
import SwiftUI
import Testing
import TetherTestSupport
import TetherPluginKit
@testable import TetherApp
#if os(macOS)
import AppKit
#endif

@MainActor
@Suite("Key bindings", .appKitEventLoop)
struct KeyBindingTests {

  private var commands: [KeyBindingCommand] { WorkspaceAction.allCases.map(\.command) }

  private func isolated(_ body: (KeyBindingStore, UserDefaults) throws -> Void) rethrows {
    let name = "key-bindings-test.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(KeyBindingStore(defaults: defaults), defaults)
  }

  @Test("a person's own Cmd-S for the tab bar outlives the default it no longer has")
  func tabBarKeepsAssignedShortcut() throws {
    try isolated { _, defaults in
      let toggle = WorkspaceAction.toggleTabBar.command
      defaults.set(try JSONEncoder().encode([toggle.id: [KeyBinding("s"), nil]]),
                   forKey: KeyBindingStore.preferenceKey)
      let loaded = KeyBindingStore(defaults: defaults)
      #expect(loaded.command(for: KeyBinding("s"), in: commands) == toggle.id)
      #expect(loaded.conflict(for: toggle, slot: 0) == nil)
      try loaded.reset(toggle, commands: commands)
      #expect(KeyBindingStore(defaults: defaults).command(for: KeyBinding("s"), in: commands) == nil)
    }
  }

  @Test("defaults leave Unix editing, navigation and process-control keys to the terminal")
  func unixDefaults() {
    isolated { store, defaults in
      let registry = PluginRegistry(defaults: defaults)
      let catalog = KeyBindingCatalog.commands(registry: registry)
      for key in "abcdefghijklmnopqrstuvwxyz".map(String.init) + ["_", "space", "[", "\\", "]", "^"] {
        #expect(store.command(for: KeyBinding(key, .control), in: catalog) == nil)
      }
      for key in ["b", "f", "d", "v", "<", ">", "backspace"] {
        #expect(store.command(for: KeyBinding(key, .option), in: catalog) == nil)
      }
      for key in ["up", "down", "left", "right"] {
        #expect(store.command(for: KeyBinding(key, []), in: catalog) == nil)
      }
    }
  }

  @Test("restoring a command cannot silently steal another command's shortcut")
  func resetConflict() throws {
    try isolated { store, defaults in
      let first = WorkspaceAction.newTerminal.command
      let second = WorkspaceAction.renameTerminal.command
      try store.set(nil, for: first, slot: 0, commands: commands)
      try store.set(KeyBinding("n"), for: second, slot: 1, commands: commands)
      #expect(throws: KeyBindingStore.BindingError.self) { try store.reset(first, commands: commands) }
      #expect(store.bindings(for: first)[0] == nil)
      store.resetAll()
      #expect(store.bindings(for: first) == first.defaults)
      #expect(store.bindings(for: second) == second.defaults)
      #expect(defaults.data(forKey: KeyBindingStore.preferenceKey) == nil)
    }
  }

  @Test("plain typing, navigation and shift-only letters cannot become application shortcuts")
  func validation() {
    #expect(!KeyBinding("x", []).isValid)
    #expect(!KeyBinding("x", .shift).isValid)
    #expect(!KeyBinding("escape", []).isValid)
    #expect(!KeyBinding("left", []).isValid)
    #expect(!KeyBinding("two keys", .control).isValid)
    #expect(!KeyBinding("\u{1b}", .control).isValid)
    #expect(KeyBinding("X", .control) == KeyBinding("x", .control))
    #expect(KeyBinding("f12", []).isValid)
    #expect(KeyBinding("space", .control).isValid)
    #expect(KeyBinding("left", .option).isValid)
    #if os(macOS)
      #expect(KeyBinding("x", [.control, .option, .shift]).label == "⌃ ⌥ ⇧ X")
    #else
      #expect(KeyBinding("x", [.control, .option, .shift]).label == "Ctrl+Alt+Shift+X")
    #endif
  }

  @Test("malformed preferences fall back to defaults without crashing")
  func malformedPreferences() throws {
    try isolated { _, defaults in
      defaults.set(Data("not json".utf8), forKey: KeyBindingStore.preferenceKey)
      #expect(KeyBindingStore(defaults: defaults).overrides.isEmpty)
      defaults.set(try JSONEncoder().encode([
        "newTerminal": [KeyBinding("n")],
        "closeTab": [KeyBinding("w", []), nil],
        "renameTerminal": [nil, KeyBinding("r", .control)],
      ]), forKey: KeyBindingStore.preferenceKey)
      let loaded = KeyBindingStore(defaults: defaults)
      #expect(loaded.overrides.count == 1)
      #expect(loaded.bindings(for: WorkspaceAction.newTerminal.command) == WorkspaceAction.newTerminal.command.defaults)
    }
  }

  #if os(macOS)
  @Test("workspace shortcut handling claims before live gates and never consumes disabled or blocked repeats")
  func workspaceShortcutLiveGates() throws {
    try isolated { _, defaults in
      let location = temporaryFile("shortcut-hosts.json")
      let secrets = MemorySecrets()
      let tabs = TabSet(defaults: defaults)
      let registry = PluginRegistry(defaults: defaults)
      let interaction = WorkspaceInteraction(tabs: tabs,
        store: HostStore(location: location, secrets: secrets), registry: registry, secrets: secrets)
      let main = interaction.workspaceHostID
      let quick = UUID()
      interaction.register(id: main, kind: .workspace)
      interaction.register(id: quick, kind: .quick)
      for id in [main, quick] {
        interaction.update(id: id, state: WorkspaceHostState(orderedIn: true, renderVisible: true))
      }
      defer { interaction.stop(); tabs.closeAll(); removeDirectory(of: location) }
      let zen = KeyBinding("z", [.command, .shift])
      @MainActor func route(_ binding: KeyBinding, repeated: Bool = false, editing: Bool = false, from host: UUID) -> Bool {
        handleWorkspaceShortcut(binding, repeated: repeated, editingText: editing,
          interaction: interaction, hostID: host, registry: registry)
      }
      #expect(route(zen, from: quick))
      #expect(tabs.zen && interaction.effectiveHost == quick)
      #expect(route(zen, repeated: true, from: quick))
      #expect(tabs.zen, "an allowed repeat is consumed but never executes")
      #expect(route(zen, from: main), "the new source claims before shortcutsAllowed is evaluated")
      #expect(!tabs.zen && interaction.effectiveHost == main)

      let lease = try #require(interaction.acquirePresentation())
      for repeated in [false, true] {
        #expect(!route(zen, repeated: repeated, from: main))
        #expect(!route(zen, repeated: repeated, from: quick))
      }
      #expect(!tabs.zen && interaction.presentationOwner == main)
      interaction.presentationDidDismiss(lease)
      for repeated in [false, true] {
        #expect(!route(KeyBinding("r"), repeated: repeated, from: main), "Rename Terminal has no target")
        #expect(!route(KeyBinding("q", [.control, .option]), repeated: repeated, from: main), "unmatched chord")
        #expect(!route(zen, repeated: repeated, editing: true, from: main), "Redo belongs to a text field")
        #expect(!route(zen, repeated: repeated, from: UUID()), "no fallback from an unknown source")
      }
      #expect(route(KeyBinding("o", [.command, .shift]), editing: true, from: main))
      #expect(tabs.palette == .command, "palette commands remain available in their search fields")
      interaction.update(id: quick, state: WorkspaceHostState())
      #expect(!route(zen, from: quick))
      #expect(!route(zen, repeated: true, from: quick))
    }
  }

  @Test("workspace shortcut handling runs only offered enabled plugin commands and consumes valid repeats without rerunning")
  func workspaceShortcutPluginResolution() throws {
    try isolated { _, defaults in
      let location = temporaryFile("shortcut-plugin-hosts.json")
      let secrets = MemorySecrets()
      let tabs = TabSet(defaults: defaults)
      let registry = PluginRegistry(defaults: defaults)
      let plugin = CataloguePlugin(id: "shortcut-fixture")
      registry.register(plugin)
      let interaction = WorkspaceInteraction(tabs: tabs,
        store: HostStore(location: location, secrets: secrets), registry: registry, secrets: secrets)
      let host = interaction.workspaceHostID
      let window = ShortcutHostWindow(contentRect: NSRect(x: -6000, y: -6000, width: 200, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      interaction.register(id: host, kind: .workspace, window: window)
      defer {
        interaction.stop(); interaction.unregister(id: host); tabs.closeAll(); window.close()
        removeDirectory(of: location)
      }
      let catalog = KeyBindingCatalog.commands(registry: registry, tabs: tabs)
      let refresh = try #require(catalog.first { $0.id == KeyBindingCatalog.commandID("refresh", plugin: plugin.metadata.id) })
      let launch = try #require(catalog.first { $0.id == KeyBindingCatalog.launchID(plugin.metadata.id) })
      let refreshChord = KeyBinding("j", [.control, .option])
      let launchChord = KeyBinding("l", [.control, .option])
      try tabs.keyBindings.set(refreshChord, for: refresh, slot: 0, commands: catalog)
      try tabs.keyBindings.set(launchChord, for: launch, slot: 0, commands: catalog)
      @MainActor func route(_ chord: KeyBinding, repeated: Bool = false) -> Bool {
        handleWorkspaceShortcut(chord, repeated: repeated, editingText: false,
          interaction: interaction, hostID: host, registry: registry)
      }
      for repeated in [false, true] {
        #expect(!route(refreshChord, repeated: repeated), "a descriptor alone is not a runnable plugin item")
        #expect(!route(launchChord, repeated: repeated), "launch requiring a missing connection is disabled")
      }
      var runs = 0
      let workspace = StubWorkspace(title: "Shortcut fixture")
      workspace.offered = [PluginCommand(id: "refresh", title: "Refresh", symbol: "arrow.clockwise") { runs += 1 }]
      tabs.openExtension(workspace, pluginID: plugin.metadata.id, hostID: nil)
      #expect(route(refreshChord))
      #expect(runs == 1)
      #expect(route(refreshChord, repeated: true))
      #expect(runs == 1)
      workspace.offered = []
      #expect(!route(refreshChord))
      #expect(!route(refreshChord, repeated: true))
      #expect(runs == 1)
    }
  }

  @Test("quick terminal appears once in unified shortcuts under Window with Control-backtick")
  func quickTerminalCatalog() throws {
    try isolated { store, defaults in
      let catalog = KeyBindingCatalog.commands(registry: PluginRegistry(defaults: defaults))
      let matches = catalog.filter { $0.id == WorkspaceAction.quickTerminal.rawValue }
      let command = try #require(matches.first)
      let binding = KeyBinding("`", .control)
      #expect(matches.count == 1)
      #expect(Set(catalog.map(\.id)).count == catalog.count)
      #expect(command == WorkspaceAction.quickTerminal.command)
      #expect(command.group == "Window")
      #expect(command.layer == .workspace)
      #expect(command.defaults == [binding, nil])
      #expect(catalog.filter { $0.defaults.contains(binding) }.map(\.id) == [command.id])
      #expect(store.command(for: binding, in: catalog) == command.id)
      #expect(store.filtered(catalog, query: "quick terminal", boundOnly: true) == [command])
      #expect(store.filtered(catalog, query: "Control+`", boundOnly: true) == [command])
    }
  }

  @Test("quick terminal's two custom shortcuts, clearing and reset persist in the unified store")
  func quickTerminalCustomization() throws {
    try isolated { store, defaults in
      let catalog = KeyBindingCatalog.commands(registry: PluginRegistry(defaults: defaults))
      let command = WorkspaceAction.quickTerminal.command
      let original = KeyBinding("`", .control)
      let primary = KeyBinding("q", [.control, .option])
      let secondary = KeyBinding("f12", [])
      try store.set(primary, for: command, slot: 0, commands: catalog)
      try store.set(secondary, for: command, slot: 1, commands: catalog)

      let loaded = KeyBindingStore(defaults: defaults)
      #expect(loaded.overrides[command.id] == [primary, secondary])
      #expect(loaded.bindings(forID: command.id) == [primary, secondary])
      #expect(loaded.command(for: primary, in: catalog) == command.id)
      #expect(loaded.command(for: secondary, in: catalog) == command.id)
      #expect(loaded.command(for: original, in: catalog) == nil)
      #expect(loaded.summary(for: command) == "\(primary.label) / \(secondary.label)")

      try loaded.set(nil, for: command, slot: 0, commands: catalog)
      let secondaryOnly = KeyBindingStore(defaults: defaults)
      #expect(secondaryOnly.bindings(for: command) == [nil, secondary])
      #expect(secondaryOnly.command(for: primary, in: catalog) == nil)
      #expect(secondaryOnly.command(for: secondary, in: catalog) == command.id)
      try secondaryOnly.set(nil, for: command, slot: 1, commands: catalog)

      let cleared = KeyBindingStore(defaults: defaults)
      #expect(cleared.overrides[command.id] == [nil, nil])
      #expect(cleared.bindings(for: command) == [nil, nil])
      #expect(cleared.command(for: original, in: catalog) == nil)
      #expect(cleared.command(for: secondary, in: catalog) == nil)
      #expect(cleared.filtered(catalog, query: "quick terminal", boundOnly: true).isEmpty)
      #expect(cleared.filtered(catalog, query: "quick terminal", boundOnly: false) == [command])

      try cleared.reset(command, commands: catalog)
      let restored = KeyBindingStore(defaults: defaults)
      #expect(restored.overrides[command.id] == nil)
      #expect(restored.bindings(forID: command.id) == [original, nil])
      #expect(restored.command(for: original, in: catalog) == command.id)
      #expect(restored.command(for: secondary, in: catalog) == nil)
    }
  }

  @Test("quick terminal cannot steal another command's shortcut in either slot", arguments: [0, 1])
  func quickTerminalConflict(slot: Int) throws {
    try isolated { store, defaults in
      let catalog = KeyBindingCatalog.commands(registry: PluginRegistry(defaults: defaults))
      let command = WorkspaceAction.quickTerminal.command
      let other = WorkspaceAction.newTerminal.command
      let binding = try #require(other.defaults[0])
      let primary = KeyBinding("q", [.control, .option])
      let secondary = KeyBinding("f12", [])
      try store.set(primary, for: command, slot: 0, commands: catalog)
      try store.set(secondary, for: command, slot: 1, commands: catalog)
      let saved = defaults.data(forKey: KeyBindingStore.syncPreferenceKey)

      #expect(throws: KeyBindingStore.BindingError.self) {
        try store.set(binding, for: command, slot: slot, commands: catalog)
      }
      #expect(store.requestedBindings(for: command) == [primary, secondary])
      #expect(defaults.data(forKey: KeyBindingStore.syncPreferenceKey) == saved)
      let loaded = KeyBindingStore(defaults: defaults)
      #expect(loaded.bindings(for: command) == [primary, secondary])
      #expect(loaded.command(for: binding, in: catalog) == other.id)
      #expect(loaded.command(for: primary, in: catalog) == command.id)
      #expect(loaded.command(for: secondary, in: catalog) == command.id)
    }
  }

  @Test("routing consumes both bindings once and leaves disabled windows, IME and unbound keys alone")
  func monitorRouting() throws {
    _ = NSApplication.shared
    let window = KeyBindingTestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
    let view = WorkspaceKeyBindingMonitor.MonitorView()
    window.contentView!.addSubview(view)
    defer { view.stop() }
    var activations = 0
    try isolated { store, _ in
      let command = WorkspaceAction.newTerminal.command
      try store.set(KeyBinding("b", .control), for: command, slot: 1, commands: commands)
      view.enabled = true
      view.handle = { binding, repeated, _ in
        guard store.command(for: binding, in: commands) != nil else { return false }
        if !repeated { activations += 1 }
        return true
      }
      @MainActor func key(_ text: String, _ modifiers: NSEvent.ModifierFlags, repeated: Bool = false,
               windowNumber: Int? = nil) throws -> NSEvent {
        let number = windowNumber ?? window.windowNumber
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
          timestamp: 0, windowNumber: number, context: nil,
          characters: text, charactersIgnoringModifiers: text, isARepeat: repeated, keyCode: 11))
      }
      #expect(view.route(try key("n", .command)) == nil)
      #expect(view.route(try key("b", .control)) == nil)
      #expect(activations == 2)
      #expect(view.route(try key("b", .control, repeated: true)) == nil)
      #expect(activations == 2)
      #expect(view.route(try key("b", .option)) != nil)
      #expect(view.route(try key("b", .control, windowNumber: 0)) != nil)
      view.enabled = false
      #expect(view.route(try key("b", .control)) != nil)
      view.enabled = true
      let field = NSTextView(frame: .zero)
      window.contentView!.addSubview(field)
      window.makeFirstResponder(field)
      field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.route(try key("b", .control)) != nil)
      #expect(activations == 2)
    }
  }

  #endif
}

@MainActor
private final class CataloguePlugin: TetherPlugin {
  let metadata: PluginMetadata
  let commandDescriptors = [PluginCommandDescriptor(id: "refresh", title: "Refresh")]
  init(id: String) { metadata = PluginMetadata(id: id, name: id, symbol: "circle", summary: "Test") }
  func launch(in context: PluginContext) {}
}

#if os(macOS)
@MainActor
private final class KeyBindingTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

/// Gives the handler a native identity without ordering a real window in or
/// changing desktop focus when a plugin command hands off to its workspace.
@MainActor
private final class ShortcutHostWindow: NSWindow {
  override var isKeyWindow: Bool { true }
  override var isVisible: Bool { true }
  override func makeKeyAndOrderFront(_ sender: Any?) {}
}
#endif
