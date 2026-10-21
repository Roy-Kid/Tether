#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import TetherApp

/// The app's window, key and main whether or not the test process is.
final class KeyedWorkspaceWindow: WorkspaceWindow {
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }
}

@MainActor
@Suite("Quick Terminal", .serialized)
struct QuickTerminalTests {
  @Test("the top half respects display origins, the menu bar and small screens; a dragged size comes back centred and clamped")
  func geometry() {
    let screen = NSRect(x: -1600, y: 924, width: 1600, height: 876)
    let minimum = NSSize(width: 760, height: 300)
    #expect(QuickTerminalController.frame(in: screen, size: nil, minimum: minimum) ==
      NSRect(x: -1600, y: 1362, width: 1600, height: 438))
    let small = NSRect(x: 0, y: 0, width: 800, height: 400)
    #expect(QuickTerminalController.frame(in: small, size: nil, minimum: NSSize(width: 760, height: 520)) == small)
    // Dragged to 1000×600: that size, hanging from the top, centred.
    #expect(QuickTerminalController.frame(in: screen, size: NSSize(width: 1000, height: 600), minimum: minimum) ==
      NSRect(x: -1300, y: 1200, width: 1000, height: 600))
    // Remembered on a bigger display: clamped to this one, never below the minimum.
    #expect(QuickTerminalController.frame(in: small, size: NSSize(width: 2000, height: 100), minimum: minimum) ==
      NSRect(x: 0, y: 100, width: 800, height: 300))
  }

  @Test("the overlay's size is remembered on its own; the ordinary window's frame is not touched")
  func rememberedSize() throws {
    let suite = "quick-terminal-size.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let window = KeyedWorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    defer { controller.stop(); window.close() }
    let original = window.frame
    controller.attach(to: window)
    controller.toggle()
    let screen = try #require(window.screen)
    #expect(window.frame == QuickTerminalController.frame(in: screen.visibleFrame, size: nil, minimum: window.minSize),
      "a display's top half until dragged: \(window.frame) on \(screen.visibleFrame), minimum \(window.minSize)")

    // A drag ends at 900×520, pulled down and to the right: that size is
    // the overlay's from now on, hung from the top again.
    let dragged = NSSize(width: 900, height: 520)
    window.setFrame(NSRect(x: window.frame.minX + 40, y: window.frame.minY - 60, width: dragged.width, height: dragged.height), display: false)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    controller.hide()
    controller.toggle()
    #expect(window.frame == QuickTerminalController.frame(in: screen.visibleFrame, size: dragged, minimum: window.minSize))
    #expect(window.frame.size == dragged)
    #expect(window.frame.maxY == screen.visibleFrame.maxY, "still a drop-down from the top")

    // A frame set by code is not a drag, and is not remembered.
    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1000, height: 600)), display: false)
    controller.hide()
    controller.toggle()
    #expect(window.frame.size == dragged)

    controller.restore()
    #expect(window.frame == original, "the ordinary window keeps its own frame")
    controller.stop()

    // The next launch remembers it too.
    let next = QuickTerminalController(defaults: defaults)
    defer { next.stop() }
    next.attach(to: window)
    next.toggle()
    #expect(window.frame.size == dragged)
    next.restore()
    #expect(window.frame == original)
  }

  @Test("toggle hides without destroying the workspace and normal mode restores geometry and behavior")
  func windowLifecycle() throws {
    let suite = "quick-terminal-window.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tabs = TabSet(defaults: defaults)
    let controller = tabs.quickTerminal
    let autosave = "quick-terminal-test.\(UUID())"
    let window = KeyedWorkspaceWindow(hosting: Color.clear, autosaveName: autosave)
    defer { controller.stop(); window.close(); UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosave)") }
    let terminal = SessionTab(preview: .local, known: KnownHosts(), name: "Kept", live: false)
    tabs.adopt(terminal)
    let original = window.frame
    let behavior = window.collectionBehavior
    controller.attach(to: window)
    tabs.perform(.quickTerminal)
    #expect(controller.isQuick)
    #expect(window.isVisible)
    #expect(window.level == .floating)
    // An overlay: key without the app, on every Space, a full-screen one
    // included, and never the main window.
    #expect(window.styleMask.contains(.nonactivatingPanel))
    #expect(!window.canBecomeMain)
    #expect(window.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
    #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
    #expect(window.frameAutosaveName.isEmpty, "the overlay's frame is not what the next launch opens at")
    tabs.perform(.quickTerminal)
    #expect(!window.isVisible)
    #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(tabs.current?.id == terminal.id)
    tabs.perform(.quickTerminal)
    #expect(window.isVisible)
    #expect(window.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
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
    #expect(window.collectionBehavior.contains(.fullScreenPrimary), "an ordinary window again, full screen and all")
    #expect(!window.styleMask.contains(.nonactivatingPanel))
    #expect(window.canBecomeMain)
    #expect(window.level == .normal)
    #expect(window.frameAutosaveName == autosave)
    #expect(tabs.current?.id == terminal.id)
  }

  @Test("the Dock brings back the ordinary window, from a hidden overlay and from one still up")
  func dockReopensOrdinary() throws {
    let suite = "quick-terminal-reopen.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let window = KeyedWorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    defer { controller.stop(); window.close() }
    let original = window.frame
    controller.attach(to: window)
    #expect(!controller.reopen(), "an ordinary window is the Dock's usual reveal")

    controller.toggle()
    controller.hide()
    #expect(controller.isQuick && !window.isVisible)
    #expect(controller.reopen())
    #expect(!controller.isQuick)
    #expect(window.isVisible)
    #expect(window.level == .normal)
    #expect(!window.styleMask.contains(.nonactivatingPanel))
    #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    #expect(window.frame == original)

    controller.toggle()
    #expect(controller.isQuick && window.isVisible)
    #expect(controller.reopen(), "an overlay still up comes back ordinary too")
    #expect(!controller.isQuick)
    #expect(window.isVisible)
    #expect(window.level == .normal)
    #expect(window.frame == original)
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

  @Test("the quick terminal opens on the display holding the frontmost window")
  func screenChoice() {
    // The window server counts from the primary display's top-left corner,
    // y down; AppKit from its bottom-left, y up. A portrait display on the
    // left, taller than the primary, reaches both above and below it.
    let primary = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    let portrait = NSRect(x: -1440, y: -1120, width: 1440, height: 2560)
    let screens = [primary, portrait]
    #expect(QuickTerminalController.screenIndex(holding: [CGRect(x: 100, y: 100, width: 500, height: 500)], screens: screens) == 0)
    #expect(QuickTerminalController.screenIndex(holding: [CGRect(x: -1000, y: 100, width: 800, height: 400)], screens: screens) == 1)
    #expect(QuickTerminalController.screenIndex(holding: [CGRect(x: -1000, y: 2000, width: 800, height: 400)], screens: screens) == 1)
    #expect(QuickTerminalController.screenIndex(holding: [CGRect(x: 3000, y: 100, width: 10, height: 10)], screens: screens) == nil)
    #expect(QuickTerminalController.screenIndex(holding: [.zero], screens: []) == nil)
    #expect(QuickTerminalController.screenIndex(holding: [], screens: screens) == nil)
    // A full-screen app's toolbar waits just above its display while hidden,
    // and is the app's frontmost window. The window behind it is on screen.
    let toolbar = CGRect(x: 0, y: -32, width: 2560, height: 32)
    let full = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    #expect(QuickTerminalController.screenIndex(holding: [toolbar, full], screens: screens) == 0)
  }

  @Test("an input source change that leaves the layout alone keeps the registration")
  func inputSourceChangeKeepsRegistration() throws {
    let suite = "quick-terminal-input-source.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let window = KeyedWindow.make()
    defer { controller.stop(); window.close() }
    controller.configure([KeyBinding("f17", [.control, .option, .command])])
    controller.attach(to: window)
    let registered = controller.hotKeys
    #expect(registered.count == 1)
    controller.keyboardChanged()
    controller.keyboardChanged()
    #expect(controller.hotKeys == registered, "switching Pinyin on and off is not a new shortcut")
    #expect(controller.shortcutProblem == nil)
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
