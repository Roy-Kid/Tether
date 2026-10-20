#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Testing
@testable import TetherApp

@MainActor
@Suite("Quick Terminal", .serialized)
struct QuickTerminalTests {
  @Test("the top half respects display origins, the menu bar and small screens")
  func geometry() {
    let screen = NSRect(x: -1600, y: 924, width: 1600, height: 876)
    #expect(QuickTerminalController.frame(in: screen, minimumHeight: 300) ==
      NSRect(x: -1600, y: 1362, width: 1600, height: 438))
    let small = NSRect(x: 0, y: 0, width: 800, height: 400)
    #expect(QuickTerminalController.frame(in: small, minimumHeight: 520) == small)
  }

  @Test("toggle hides without destroying the workspace and normal mode restores geometry and behavior")
  func windowLifecycle() throws {
    let suite = "quick-terminal-window.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tabs = TabSet(defaults: defaults)
    let controller = tabs.quickTerminal
    let window = KeyedWindow.make()
    defer { controller.stop(); window.close() }
    let terminal = SessionTab(preview: .local, known: KnownHosts(), name: "Kept", live: false)
    tabs.adopt(terminal)
    let original = window.frame
    let behavior = window.collectionBehavior
    controller.attach(to: window)
    tabs.perform(.quickTerminal)
    #expect(controller.isQuick)
    #expect(window.isVisible)
    #expect(window.level == .floating)
    #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(window.collectionBehavior.contains(.canJoinAllApplications))
    tabs.perform(.quickTerminal)
    #expect(!window.isVisible)
    #expect(tabs.current?.id == terminal.id)
    tabs.perform(.quickTerminal)
    #expect(window.isVisible)
    let elsewhere = KeyedWindow.make()
    defer { elsewhere.close() }
    elsewhere.makeKeyAndOrderFront(nil)
    controller.statusItemClicked()
    #expect(!window.isVisible, "the menu bar closes it even after the click took the key")
    controller.statusItemClicked()
    #expect(window.isVisible)
    #expect(controller.isQuick)
    tabs.perform(.restoreWindow)
    #expect(!controller.isQuick)
    #expect(window.frame == original)
    #expect(window.collectionBehavior == behavior)
    #expect(window.level == .normal)
    #expect(tabs.current?.id == terminal.id)
  }

  @Test("status menu follows visibility and reuses the existing window actions")
  func statusMenu() throws {
    let suite = "quick-terminal-menu.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let window = KeyedWindow.make()
    let closeGuard = HideInsteadOfClose(forwarding: window.delegate)
    window.delegate = closeGuard
    defer { controller.stop(); window.delegate = nil; window.close() }
    controller.attach(to: window)
    let original = window.frame
    let initial = controller.statusMenu()
    #expect(initial.items.map(\.title) == ["Show Quick Terminal", "Restore Window", "", "Close Window", "", "Quit Tether"])
    #expect(initial.items[1].isEnabled == false)
    #expect(initial.items.last?.action == #selector(NSApplication.terminate(_:)))
    #expect(initial.items.last?.target === NSApplication.shared)
    let show = try #require(initial.items.first)
    #expect(NSApplication.shared.sendAction(try #require(show.action), to: show.target, from: show))
    #expect(controller.isQuick && window.isVisible)
    let visible = controller.statusMenu()
    #expect(visible.items[0].title == "Hide Quick Terminal")
    #expect(visible.items[1].isEnabled)
    let hide = visible.items[0]
    #expect(NSApplication.shared.sendAction(try #require(hide.action), to: hide.target, from: hide))
    #expect(!window.isVisible)
    let hidden = controller.statusMenu()
    #expect(hidden.items[0].title == "Show Quick Terminal")
    #expect(!hidden.items[3].isEnabled)
    let restore = hidden.items[1]
    #expect(NSApplication.shared.sendAction(try #require(restore.action), to: restore.target, from: restore))
    #expect(!controller.isQuick && window.isVisible)
    #expect(window.frame == original)
    let close = controller.statusMenu().items[3]
    #expect(NSApplication.shared.sendAction(try #require(close.action), to: close.target, from: close))
    #expect(!window.isVisible)
    #expect(window.delegate === closeGuard, "closing keeps the existing session-preserving delegate")
  }

  @Test("disabling Quick Terminal restores the window; topmost is independent and persisted")
  func preferences() throws {
    let suite = "quick-terminal-preferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let window = KeyedWindow.make()
    defer { controller.stop(); window.close() }
    let frame = window.frame
    controller.attach(to: window)
    controller.alwaysOnTop = true
    #expect(window.level == .floating)
    controller.toggle()
    controller.autoHide = false
    controller.enabled = false
    #expect(!controller.isQuick)
    #expect(window.frame == frame)
    #expect(window.level == .floating)
    controller.toggle()
    #expect(!controller.isQuick)
    let restored = QuickTerminalController(defaults: defaults)
    #expect(!restored.enabled)
    #expect(restored.alwaysOnTop)
    #expect(!restored.autoHide)
    #expect(restored.showsMenuBarIcon)
    controller.showsMenuBarIcon = false
    #expect(!QuickTerminalController(defaults: defaults).showsMenuBarIcon)
    controller.alwaysOnTop = false
    #expect(window.level == .normal)
  }

  @Test("system-wide registrations report conflicts, suspend for recording and release on stop")
  func hotKeyLifecycle() throws {
    let suite = "quick-terminal-hotkey.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let window = KeyedWindow.make()
    defer { controller.stop(); window.close() }
    let binding = KeyBinding("f19", [.control, .option, .command])
    let code = try #require(binding.carbonKeyCode)
    var competitor: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(code), binding.carbonModifiers,
      EventHotKeyID(signature: 0x54455354, id: 100), GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive), &competitor)
    try #require(status == noErr)
    defer { if let competitor { UnregisterEventHotKey(competitor) } }
    controller.configure([binding, nil])
    controller.attach(to: window)
    #expect(controller.shortcutProblem != nil)
    if let competitor { UnregisterEventHotKey(competitor) }
    competitor = nil
    controller.recordingShortcut = true
    controller.recordingShortcut = false
    #expect(controller.shortcutProblem == nil)
    let registerCompetitor = {
      RegisterEventHotKey(UInt32(code), binding.carbonModifiers,
        EventHotKeyID(signature: 0x54455354, id: 100), GetApplicationEventTarget(),
        OptionBits(kEventHotKeyExclusive), &competitor)
    }
    #expect(registerCompetitor() != noErr)
    controller.recordingShortcut = true
    #expect(registerCompetitor() == noErr)
    if let competitor { UnregisterEventHotKey(competitor) }
    competitor = nil
    controller.recordingShortcut = false
    controller.stop()
    #expect(registerCompetitor() == noErr)
  }

  @Test("editing bindings updates the global registration while the window is hidden")
  func editsWhileHidden() async throws {
    let suite = "quick-terminal-edit.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = KeyBindingStore(defaults: defaults)
    let controller = QuickTerminalController(defaults: defaults)
    let window = KeyedWindow.make()
    defer { controller.stop(); window.close() }
    let binding = KeyBinding("f18", [.control, .option, .command])
    let command = WorkspaceAction.quickTerminal.command
    try store.set(binding, for: command, slot: 0, commands: WorkspaceAction.allCases.map(\.command))
    controller.useBindings(store)
    controller.attach(to: window)
    controller.toggle()
    controller.hide()
    #expect(!window.isVisible)
    #expect(controller.shortcutProblem == nil)
    try store.set(nil, for: command, slot: 0, commands: WorkspaceAction.allCases.map(\.command))
    try await Task.sleep(for: .milliseconds(50))
    var ref: EventHotKeyRef?
    defer { if let ref { UnregisterEventHotKey(ref) } }
    #expect(store.bindings(for: command).allSatisfy { $0 == nil })
    let code = try #require(binding.carbonKeyCode)
    let status = RegisterEventHotKey(UInt32(code), binding.carbonModifiers,
      EventHotKeyID(signature: 0x54455354, id: 101), GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive), &ref)
    #expect(status == noErr)
    #expect(!window.isVisible)
  }

  @Test("global key translation shares the local ASCII layout and named keys")
  func keyTranslation() throws {
    let binding = WorkspaceAction.quickTerminal.command.defaults[0]
    #expect(binding == KeyBinding("`", .control))
    let code = try #require(binding?.carbonKeyCode)
    #expect(KeyBinding.asciiCharacter(keyCode: code) == "`")
    #expect(binding?.carbonModifiers == UInt32(controlKey))
    #expect(KeyBinding("f20", []).carbonKeyCode == 90)
    #expect(KeyBinding("space", .option).carbonKeyCode == 49)
    #expect(KeyBinding("left", .control).carbonKeyCode == 123)
    #expect(KeyBinding("not a key", .control).carbonKeyCode == nil)
  }
}
#endif
