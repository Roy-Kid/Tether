import Foundation
import SwiftUI
import Testing
import TetherPluginKit
@testable import TetherApp
#if os(macOS)
import AppKit
#endif

@MainActor
@Suite("Key bindings")
struct KeyBindingTests {
  private var commands: [KeyBindingCommand] { WorkspaceAction.allCases.map(\.command) }

  private func isolated(_ body: (KeyBindingStore, UserDefaults) throws -> Void) rethrows {
    let name = "key-bindings-test.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(KeyBindingStore(defaults: defaults), defaults)
  }

  @Test("existing command-menu bindings both dispatch by default")
  func defaultBindings() {
    isolated { store, _ in
      #expect(store.command(for: KeyBinding("p", [.control, .shift]), in: commands) == "commandMenu")
      #expect(store.command(for: KeyBinding("p", [.command, .shift]), in: commands) == "commandMenu")
      #expect(store.command(for: KeyBinding("p"), in: commands) == "quickSwitch")
      #expect(store.command(for: KeyBinding("b", .option), in: commands) == nil)
      let assigned = commands.flatMap { store.bindings(for: $0).compactMap { $0 } }
      #expect(Set(assigned).count == assigned.count)
      #expect(commands.allSatisfy { store.bindings(for: $0).count == 2 })
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

  @Test("two independent alternatives persist, and cleared defaults stay cleared after relaunch")
  func persistence() throws {
    try isolated { store, defaults in
      let command = WorkspaceAction.newTerminal.command
      try store.set(KeyBinding("n", .control), for: command, slot: 0, commands: commands)
      try store.set(KeyBinding("n", .option), for: command, slot: 1, commands: commands)
      let loaded = KeyBindingStore(defaults: defaults)
      #expect(loaded.command(for: KeyBinding("n", .control), in: commands) == command.id)
      #expect(loaded.command(for: KeyBinding("n", .option), in: commands) == command.id)
      #expect(loaded.command(for: KeyBinding("n"), in: commands) == nil)
      try loaded.set(nil, for: command, slot: 0, commands: commands)
      try loaded.set(nil, for: command, slot: 1, commands: commands)
      #expect(KeyBindingStore(defaults: defaults).bindings(for: command) == [nil, nil])
      try loaded.reset(command, commands: commands)
      #expect(KeyBindingStore(defaults: defaults).bindings(for: command) == command.defaults)
    }
  }

  @Test("conflicts across slots and commands are rejected without changing either binding")
  func conflicts() throws {
    try isolated { store, _ in
      let command = WorkspaceAction.newTerminal.command
      #expect(throws: KeyBindingStore.BindingError.self) {
        try store.set(KeyBinding("p", [.control, .shift]), for: command, slot: 1, commands: commands)
      }
      #expect(throws: KeyBindingStore.BindingError.self) {
        try store.set(KeyBinding("n"), for: command, slot: 1, commands: commands)
      }
      #expect(store.bindings(for: command) == command.defaults)
      try store.set(KeyBinding("n"), for: command, slot: 0, commands: commands)
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
      #expect(store.bindings(for: second) == [nil, nil])
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
    #expect(KeyBinding("x", [.control, .option, .shift]).label == "Ctrl+Alt+Shift+X")
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
      #expect(loaded.bindings(for: WorkspaceAction.newTerminal.command) == [KeyBinding("n"), nil])
    }
  }

  @Test("search covers groups and shortcuts, and bound-only includes a secondary-only assignment")
  func filtering() throws {
    try isolated { store, _ in
      let rename = WorkspaceAction.renameTerminal.command
      #expect(store.filtered(commands, query: "", boundOnly: true).contains(rename) == false)
      try store.set(KeyBinding("r", .control), for: rename, slot: 1, commands: commands)
      #expect(store.filtered(commands, query: "ctrl+r", boundOnly: true) == [rename])
      #expect(store.filtered(commands, query: "window", boundOnly: false).count == 2)
      #expect(store.filtered(commands, query: "nothing matches", boundOnly: false).isEmpty)
    }
  }

  @Test("inactive plugins expose commands before connecting, with namespaced IDs")
  func pluginCatalogue() {
    isolated { _, defaults in
      let registry = PluginRegistry(defaults: defaults)
      registry.register(CataloguePlugin(id: "one"))
      registry.register(CataloguePlugin(id: "two"))
      registry.setEnabled(false, id: "one")
      let catalog = KeyBindingCatalog.commands(registry: registry)
      #expect(catalog.contains { $0.id == "plugin.one.command.refresh" })
      #expect(catalog.contains { $0.id == "plugin.two.command.refresh" })
      #expect(catalog.contains { $0.id == "plugin.one.launch" })
      #expect(Set(catalog.map(\.id)).count == catalog.count)
    }
  }

  @Test("command dispatch respects availability and close dismisses overlays first")
  func dispatch() {
    let tabs = TabSet()
    #expect(!tabs.canPerform(.closeTab))
    #expect(!tabs.canPerform(.renameTerminal))
    tabs.perform(.commandMenu)
    #expect(tabs.palette == .command)
    tabs.perform(.closeTab)
    #expect(tabs.palette == nil)
    tabs.perform(.zen)
    #expect(tabs.zen)
    #expect(!tabs.canPerform(.inspector))
    tabs.perform(.inspector)
    #expect(!tabs.inspector)
    tabs.perform(.newTerminal)
    #expect(tabs.intent == .newTerminal)
  }

  #if os(macOS)
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
      view.handle = { binding, repeated in
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

  @Test("Ctrl and Alt use the logical base key, ignoring caps lock and function flags")
  func eventNormalization() throws {
    func event(_ characters: String, _ base: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 11) throws -> NSEvent {
      try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: base, isARepeat: false, keyCode: code))
    }
    #expect(KeyBinding(event: try event("∫", "b", .option)) == KeyBinding("b", .option))
    #expect(KeyBinding(event: try event("\u{02}", "b", .control)) == KeyBinding("b", .control))
    #expect(KeyBinding(event: try event("B", "B", [.control, .capsLock])) == KeyBinding("b", .control))
    #expect(KeyBinding(event: try event("", "", [.option, .function], code: 123)) == KeyBinding("left", .option))
    #expect(KeyBinding(event: try event("\u{f704}", "\u{f704}", .function, code: 122)) == KeyBinding("f1", []))
    #expect(KeyBinding("left", [.option, .command]).keyboardShortcut?.key == .leftArrow)
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
#endif
