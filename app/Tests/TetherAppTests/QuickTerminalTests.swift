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

  /// A panel the way the app makes the quick terminal: the workspace window.
  private func panel() -> KeyedWorkspaceWindow {
    KeyedWorkspaceWindow(hosting: Color.clear, autosaveName: nil)
  }

  @Test("the overlay's size is remembered on its own, here and across launches")
  func rememberedSize() throws {
    let suite = "quick-terminal-size.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let window = panel()
    defer { controller.stop(); window.close() }
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
    controller.stop()

    // The next launch remembers it too.
    let next = QuickTerminalController(defaults: defaults)
    defer { next.stop() }
    next.attach(to: window)
    next.toggle()
    #expect(window.frame.size == dragged)
  }

  @Test("the quick terminal is a panel of its own; showing and hiding it leaves the ordinary window alone")
  func separateFromTheOrdinaryWindow() throws {
    let suite = "quick-terminal-window.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tabs = TabSet(defaults: defaults)
    let controller = tabs.quickTerminal
    let main = KeyedWorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    var made: [KeyedWorkspaceWindow] = []
    defer { controller.stop(); main.close(); for window in made { window.close() } }
    main.makeKeyAndOrderFront(nil)
    let frame = main.frame
    let behavior = main.collectionBehavior
    controller.attachMain(main)
    controller.provide {
      let window = self.panel()
      made.append(window)
      return window
    }
    #expect(made.isEmpty, "nothing is made until the quick terminal is asked for")

    tabs.perform(.quickTerminal)
    let quick = try #require(made.first)
    #expect(made.count == 1)
    #expect(quick !== main)
    #expect(quick.isVisible)
    #expect(controller.isShown)
    // An overlay: key without the app, on every Space, a full-screen one
    // included, never the main window, and never full screen itself.
    #expect(quick.level == .floating)
    #expect(quick.styleMask.contains(.nonactivatingPanel))
    #expect(!quick.canBecomeMain)
    #expect(quick.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
    #expect(!quick.collectionBehavior.contains(.fullScreenPrimary))
    #expect(quick.frameAutosaveName.isEmpty)

    // The ordinary window is exactly as it was, and still on screen.
    #expect(main.isVisible, "showing the quick terminal does not take the ordinary window away")
    #expect(main.frame == frame)
    #expect(main.collectionBehavior == behavior)
    #expect(main.level == .normal)
    #expect(!main.styleMask.contains(.nonactivatingPanel))
    #expect(main.canBecomeMain)

    tabs.perform(.quickTerminal)
    #expect(!quick.isVisible)
    #expect(main.isVisible, "hiding it leaves the ordinary window too")
    #expect(main.frame == frame)

    tabs.perform(.quickTerminal)
    #expect(quick.isVisible)
    #expect(made.count == 1, "the same panel comes back, with its tabs")
    let elsewhere = KeyedWindow.make()
    defer { elsewhere.close() }
    elsewhere.makeKeyAndOrderFront(nil)
    controller.statusItemClicked()
    #expect(!quick.isVisible, "the menu bar closes it even after the click took the key")
    controller.statusItemClicked()
    #expect(quick.isVisible)
    #expect(main.isVisible && main.frame == frame)
  }

  @Test("two windows on one set of tabs: the one in front is the last key while shown, whatever order they report in")
  func frontWindow() throws {
    let suite = "quick-terminal-front.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tabs = TabSet(defaults: defaults)
    let main = UUID()
    let quick = UUID()
    #expect(tabs.isFront(main) && tabs.isFront(quick), "with none noted, either may act")
    tabs.note(window: main, shown: true, key: true)
    tabs.note(window: quick, shown: false, key: false)
    #expect(tabs.isFront(main) && !tabs.isFront(quick))

    // The overlay takes the key before the ordinary window reports losing it.
    tabs.note(window: quick, shown: true, key: true)
    tabs.note(window: main, shown: true, key: false)
    #expect(tabs.isFront(quick) && !tabs.isFront(main))
    #expect(tabs.keyWindows == [quick])
    #expect(tabs.shownWindows == [main, quick])

    // Hidden, it hands the front to the window still on screen, key or not.
    tabs.note(window: quick, shown: false, key: false)
    #expect(tabs.isFront(main))
    #expect(tabs.keyWindows.isEmpty)
    #expect(tabs.shownWindows == [main])

    // The other order: the ordinary window loses the key first.
    tabs.note(window: main, shown: true, key: true)
    tabs.note(window: main, shown: true, key: false)
    tabs.note(window: quick, shown: true, key: true)
    #expect(tabs.isFront(quick))
    // Another app in front: neither is key, and the last one in front stays.
    tabs.note(window: quick, shown: true, key: false)
    #expect(tabs.isFront(quick) && tabs.keyWindows.isEmpty)
  }

  @Test("status menu shows or hides the quick terminal, and quits")
  func statusMenu() throws {
    let suite = "quick-terminal-menu.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let window = panel()
    defer { controller.stop(); window.close() }
    controller.attach(to: window)
    let initial = controller.statusMenu()
    #expect(initial.items.map(\.title) == ["Show Quick Terminal", "", "Quit Tether"])
    #expect(initial.items.last?.action == #selector(NSApplication.terminate(_:)))
    #expect(initial.items.last?.target === NSApplication.shared)
    let show = try #require(initial.items.first)
    #expect(NSApplication.shared.sendAction(try #require(show.action), to: show.target, from: show))
    #expect(controller.isShown && window.isVisible)
    let visible = controller.statusMenu()
    #expect(visible.items[0].title == "Hide Quick Terminal")
    let hide = visible.items[0]
    #expect(NSApplication.shared.sendAction(try #require(hide.action), to: hide.target, from: hide))
    #expect(!window.isVisible)
    #expect(controller.statusMenu().items[0].title == "Show Quick Terminal")
  }

  @Test("disabling Quick Terminal hides it; on top is the ordinary window's, and persisted")
  func preferences() throws {
    let suite = "quick-terminal-preferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let main = KeyedWindow.make()
    let window = panel()
    defer { controller.stop(); main.close(); window.close() }
    controller.attachMain(main)
    controller.attach(to: window)
    controller.alwaysOnTop = true
    #expect(main.level == .floating)
    controller.toggle()
    #expect(window.isVisible)
    controller.autoHide = false
    controller.enabled = false
    #expect(!window.isVisible)
    #expect(window.level == .floating, "the overlay floats whatever on top says")
    controller.toggle()
    #expect(!window.isVisible)
    let restored = QuickTerminalController(defaults: defaults)
    #expect(!restored.enabled)
    #expect(restored.alwaysOnTop)
    #expect(!restored.autoHide)
    #expect(restored.showsMenuBarIcon)
    controller.showsMenuBarIcon = false
    #expect(!QuickTerminalController(defaults: defaults).showsMenuBarIcon)
    controller.alwaysOnTop = false
    #expect(main.level == .normal)
    #expect(window.level == .floating)
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
