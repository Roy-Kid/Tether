import Foundation
import Testing
import TetherPluginKit
import TetherUI
@testable import TetherApp
import FilesPlugin
import PortsPlugin
import TmuxPlugin
#if os(macOS)
import AppKit
#endif

/// The shortcut table as a whole: which chord runs what, and where a
/// plugin's command takes a chord from the window's.
@MainActor
@Suite("Shortcut table")
struct ShortcutTableTests {
  private func isolated(_ body: (KeyBindingStore, UserDefaults) throws -> Void) rethrows {
    let name = "shortcut-table-test.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(KeyBindingStore(defaults: defaults), defaults)
  }

  /// The registry the app ships with.
  private func shipped(_ defaults: UserDefaults) -> PluginRegistry {
    let registry = PluginRegistry(defaults: defaults)
    registry.register(TmuxPlugin())
    registry.register(FilesPlugin())
    registry.register(PortsPlugin())
    return registry
  }

  @Test("no default chord is claimed twice in a layer; plugins overlay only the window's splits")
  func shippedDefaults() {
    isolated { store, defaults in
      let catalog = KeyBindingCatalog.commands(registry: shipped(defaults))
      for layer in [KeyBindingLayer.workspace, .attachment] {
        let chords = catalog.filter { $0.layer == layer }.flatMap { $0.defaults.compactMap { $0 } }
        #expect(Set(chords).count == chords.count, "\(layer)")
        #expect(chords.allSatisfy { $0.isValid })
      }
      #expect(catalog.allSatisfy { command in (0..<2).allSatisfy { store.conflict(for: command, slot: $0) == nil } })
      let window = Set(catalog.filter { $0.layer == .workspace }.flatMap { $0.defaults.compactMap { $0 } })
      let overlaid = catalog.filter { $0.layer == .attachment && $0.defaults.contains { $0.map(window.contains) == true } }
      #expect(Set(overlaid.map(\.title)) == ["Split Left and Right", "Split Top and Bottom"])
    }
  }

  @Test("an offered attachment command wins its chord; otherwise the window's command runs")
  func attachmentOverlay() throws {
    try isolated { store, defaults in
      let registry = PluginRegistry(defaults: defaults)
      registry.register(ChordPlugin())
      let catalog = KeyBindingCatalog.commands(registry: registry)
      let split = KeyBindingCatalog.commandID("split", plugin: ChordPlugin.id)
      let only = KeyBindingCatalog.commandID("only", plugin: ChordPlugin.id)
      #expect(store.command(for: KeyBinding("\\"), in: catalog) == "splitRight")
      #expect(store.command(for: KeyBinding("\\"), in: catalog, offered: [split]) == split)
      #expect(store.command(for: KeyBinding("y", [.command, .shift]), in: catalog, offered: [split]) == nil,
              "a plugin chord nobody offers leaves the key to the menus and the terminal")
      #expect(store.command(for: KeyBinding("y", [.command, .shift]), in: catalog, offered: [only]) == only)
      // Across layers is an overlay, not a conflict; within one it still is.
      let splitCommand = try #require(catalog.first { $0.id == split })
      #expect(store.conflict(for: splitCommand, slot: 0) == nil)
      #expect(store.conflict(for: WorkspaceAction.splitRight.command, slot: 0) == nil)
      let onlyCommand = try #require(catalog.first { $0.id == only })
      try store.set(KeyBinding("t"), for: onlyCommand, slot: 1, commands: catalog)
      #expect(throws: KeyBindingStore.BindingError.self) {
        try store.set(KeyBinding("\\"), for: onlyCommand, slot: 1, commands: catalog)
      }
      try store.reset(splitCommand, commands: catalog)
      #expect(store.bindings(forID: split) == [KeyBinding("\\"), nil])
    }
  }

  @Test("the menu bar shows the window's chord only while no offered command holds it")
  func menuShortcut() throws {
    let tabs = TabSet()
    tabs.keyBindings.register(KeyBindingCatalog.commands(registry: {
      let registry = PluginRegistry(defaults: UserDefaults(suiteName: "menu-shortcut.\(UUID())")!)
      registry.register(ChordPlugin())
      return registry
    }()))
    let shell = SessionTab(preview: .local, known: KnownHosts(location: URL(fileURLWithPath: "/dev/null")),
                           name: "a", live: true)
    tabs.adopt(shell)
    let attachment = StubAttachment()
    shell.attach(attachment, for: ChordPlugin.id)
    #expect(tabs.menuShortcut(for: .splitRight) == KeyBinding("\\"))
    attachment.offered = [PluginCommand(id: "split", title: "Split", symbol: "square") {}]
    #expect(tabs.offeredCommandIDs == [KeyBindingCatalog.commandID("split", plugin: ChordPlugin.id)])
    #expect(tabs.menuShortcut(for: .splitRight) == nil)
    #expect(tabs.menuShortcut(for: .splitDown) == KeyBinding("\\", [.command, .shift]))
  }

  @Test("customised close shortcuts survive the new defaults, which still apply where untouched")
  func customisedCloses() throws {
    try isolated { _, defaults in
      let commands = WorkspaceAction.allCases.map(\.command)
      let legacy: [String: [KeyBinding?]] = [
        "closeTab": [KeyBinding("w"), nil],
        "closeTerminal": [KeyBinding("w", [.command, .shift]), nil],
      ]
      defaults.set(try JSONEncoder().encode(legacy), forKey: KeyBindingStore.preferenceKey)
      let store = KeyBindingStore(defaults: defaults)
      #expect(store.command(for: KeyBinding("w"), in: commands) == "closeTab")
      #expect(store.command(for: KeyBinding("w", [.command, .shift]), in: commands) == "closeTerminal")
      #expect(store.conflict(for: WorkspaceAction.closeWindow.command, slot: 0) != nil)
      #expect(store.command(for: KeyBinding("w", [.command, .option]), in: commands) == nil,
              "the custom Close Tab replaced its default")
      #expect(WorkspaceAction.closeTerminal.command.defaults == [KeyBinding("w"), nil])
    }
  }

  @Test("while text is being edited only the palette and close commands keep their chords")
  func textFieldsFirst() {
    #expect(!WorkspaceAction.answersWhileEditingText(WorkspaceAction.zen.rawValue), "⇧⌘Z there is Redo")
    #expect(!WorkspaceAction.answersWhileEditingText(WorkspaceAction.splitRight.rawValue))
    #expect(!WorkspaceAction.answersWhileEditingText(KeyBindingCatalog.commandID("split", plugin: "p")))
    for action: WorkspaceAction in [.commandMenu, .quickSwitch, .closeTerminal, .closeTab, .closeWindow] {
      #expect(WorkspaceAction.answersWhileEditingText(action.rawValue))
    }
  }

  @Test("quitting asks only while a terminal is live, and Return is not the answer")
  func quit() throws {
    #expect(QuitConfirmation.decision(live: 0) == .quit)
    #expect(QuitConfirmation.decision(live: 1) == .ask)
    #expect(QuitConfirmation.decision(live: 3) == .ask)
    let dialog = QuitConfirmation.dialog(live: 2)
    #expect(dialog.title == "Quit Tether?")
    #expect(dialog.message == "2 terminals will stop.")
    #expect(QuitConfirmation.dialog(live: 1).message == "1 terminal will stop.")
    let verb = try #require(dialog.actions.last)
    #expect(verb.title == "Quit")
    #expect(verb.role == .destructive)
    #expect(verb.shortcuts == [.command("q")])
    #expect(dialog.defaultAction == nil, "Return does not quit")
    #expect(dialog.cancelAction != nil)
    #if os(macOS)
      let tabs = TabSet()
      tabs.adopt(SessionTab(preview: .local, known: KnownHosts(location: URL(fileURLWithPath: "/dev/null")),
                            name: "ended", live: false))
      #expect(tabs.liveTerminalCount == 0)
      #expect(QuitGate().shouldTerminate(NSApplication.shared, tabs: tabs) == .terminateNow)
      #expect(QuitGate().shouldTerminate(NSApplication.shared, tabs: nil) == .terminateNow)
    #endif
  }

  #if os(macOS)
  @Test("the monitor says when a text view is being edited, and the terminal is not one")
  func editingTextFlag() throws {
    _ = NSApplication.shared
    let window = TableTestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
    let view = WorkspaceKeyBindingMonitor.MonitorView()
    window.contentView!.addSubview(view)
    defer { view.stop() }
    var editing: [Bool] = []
    view.enabled = true
    view.handle = { _, _, text in editing.append(text); return !text }
    let zen = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6))
    let plain = FocusableView(frame: .zero)
    window.contentView!.addSubview(plain)
    window.makeFirstResponder(plain)
    #expect(view.route(zen) == nil)
    let field = NSTextView(frame: .zero)
    window.contentView!.addSubview(field)
    window.makeFirstResponder(field)
    #expect(view.route(zen) === zen, "declined, so the field and its Edit menu get it")
    #expect(editing == [false, true])
    field.isEditable = false
    #expect(!WorkspaceKeyBindingMonitor.MonitorView.isEditingText(field))
  }

  @Test("Shift is a modifier of the chord, not part of its key")
  func shiftedPunctuation() throws {
    func event(_ characters: String, code: UInt16) throws -> NSEvent {
      try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
        timestamp: 0, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    // ANSI key codes for [ ] \ and Z.
    #expect(KeyBinding.unshifted(try event("{", code: 33)) == KeyBinding("[", [.command, .shift]))
    #expect(KeyBinding.unshifted(try event("}", code: 30)) == KeyBinding("]", [.command, .shift]))
    #expect(KeyBinding.unshifted(try event("|", code: 42)) == KeyBinding("\\", [.command, .shift]))
    #expect(KeyBinding(event: try event("|", code: 42)) == KeyBinding("|", [.command, .shift]),
            "what was typed stays the first reading, for chords people recorded")
    #expect(KeyBinding.unshifted(try event("Z", code: 6)) == nil, "a letter reads the same either way")
  }
  #endif
}

@MainActor
private final class ChordPlugin: TetherPlugin {
  static let id = "chords"
  let metadata = PluginMetadata(id: ChordPlugin.id, name: "Chords", symbol: "circle", summary: "Test")
  let commandDescriptors = [
    PluginCommandDescriptor(id: "split", title: "Split", shortcut: PluginKeyChord("\\")),
    PluginCommandDescriptor(id: "only", title: "Only", shortcut: PluginKeyChord("y", [.command, .shift])),
  ]
  func launch(in context: PluginContext) {}
}

#if os(macOS)
@MainActor
private final class TableTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

private final class FocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
#endif
