import Foundation
import Testing
import TetherTestSupport
import TetherPluginKit
import TetherUI
@testable import TetherApp
import FilesPlugin
import PortsPlugin
import TmuxPlugin
#if os(macOS)
import AppKit
import SwiftUI
#endif

/// The shortcut table as a whole: which chord runs what, and where a
/// plugin's command takes a chord from the window's.
@MainActor
@Suite("Shortcut table", .appKitEventLoop)
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

  @Test("a shifted letter menu item matches the chord the terminal receives")
  func shiftedLetterMenuEquivalent() throws {
    let target = MenuActionTarget()
    let menu = NSMenu()
    let change = NSMenuItem(title: "Change Host…", action: #selector(MenuActionTarget.changeHost(_:)), keyEquivalent: "h")
    change.keyEquivalentModifierMask = [.command, .shift]
    change.target = target
    menu.addItem(change)
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(redo)
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
      windowNumber: 0, context: nil, characters: "H", charactersIgnoringModifiers: "H",
      isARepeat: false, keyCode: 4))
    let commands = [WorkspaceAction.changeHost.command, WorkspaceAction.zen.command]
    #expect(!menu.performKeyEquivalent(with: event), "SwiftUI's lowercase form does not match")
    MenuKeyEquivalents.normalize(menu, commands: commands, editingText: false) { $0.defaults }
    #expect(menu.performKeyEquivalent(with: event),
      "equiv \(change.keyEquivalent) shift \(change.keyEquivalentModifierMask.contains(.shift)) fired \(target.fired)")
    #expect(change.keyEquivalent == "H")
    #expect(!change.keyEquivalentModifierMask.contains(.shift))
    #expect(redo.keyEquivalent == "z", "Redo keeps ⇧⌘Z")
    MenuKeyEquivalents.normalize(menu, commands: commands, editingText: true) { $0.defaults }
    #expect(change.keyEquivalent == "h")
    #expect(change.keyEquivalentModifierMask.contains(.shift))
    #expect(!menu.performKeyEquivalent(with: event), "a text field keeps ⇧⌘H")
  }

  #endif
}

#if os(macOS)
private final class ForcedKeyPanel: WorkspaceWindow {
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }
}

@MainActor
private final class ShortcutHit {
  var count = 0
}

private struct ShortcutHost: View {
  let hit: ShortcutHit

  var body: some View {
    TerminalCapture()
      .frame(width: 420, height: 280)
      .background {
        WorkspaceKeyBindingMonitor(enabled: true) { binding, _, editing in
          guard binding == KeyBinding("h", [.command, .shift]), !editing else { return false }
          hit.count += 1
          return true
        }
      }
  }
}

private struct TerminalCapture: NSViewRepresentable {
  func makeNSView(context: Context) -> TerminalCaptureView { TerminalCaptureView() }
  func updateNSView(_ nsView: TerminalCaptureView, context: Context) {}

  final class TerminalCaptureView: NSView {
    var sawKey = false
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func keyDown(with event: NSEvent) { sawKey = true }
  }
}

@MainActor
private func findMonitor(in view: NSView) -> WorkspaceKeyBindingMonitor.MonitorView? {
  if let view = view as? WorkspaceKeyBindingMonitor.MonitorView { return view }
  return view.subviews.lazy.compactMap { findMonitor(in: $0) }.first
}

@MainActor
private func findCapture(in view: NSView) -> TerminalCapture.TerminalCaptureView? {
  if let view = view as? TerminalCapture.TerminalCaptureView { return view }
  return view.subviews.lazy.compactMap { findCapture(in: $0) }.first
}
#endif

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

private final class MenuActionTarget: NSObject {
  var fired = 0
  @objc func changeHost(_ sender: Any?) { fired += 1 }
}
#endif
