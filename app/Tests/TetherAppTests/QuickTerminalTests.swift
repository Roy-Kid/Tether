#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import TetherTestSupport
@testable import TetherApp

/// The quick panel the way a summon finds it, which a test process cannot
/// otherwise make: always key, so `toggle()` takes the hide path.
final class KeyedQuickPanel: QuickTerminalWindow {
  override var isKeyWindow: Bool { true }
}

/// Key until a test says it resigned, so a resign-key notification is what
/// dismisses the overlay.
final class ResignableQuickPanel: QuickTerminalWindow {
  var reportsKey = true
  override var isKeyWindow: Bool { reportsKey }
}

@MainActor
@Suite("Quick Terminal", .serialized, .appKitEventLoop)
struct QuickTerminalTests {
  @Test("the top third respects display origins, the menu bar and small screens; a dragged size comes back centred and clamped")
  func geometry() {
    let screen = NSRect(x: -1600, y: 924, width: 1600, height: 876)
    let minimum = NSSize(width: 760, height: 300)
    #expect(QuickTerminalController.frame(in: screen, size: nil, minimum: minimum) ==
      NSRect(x: -1600, y: 1500, width: 1600, height: 300))
    let small = NSRect(x: 0, y: 0, width: 800, height: 400)
    #expect(QuickTerminalController.frame(in: small, size: nil, minimum: NSSize(width: 760, height: 520)) == small)
    // Dragged to 1000×600: that size, hanging from the top, centred.
    #expect(QuickTerminalController.frame(in: screen, size: NSSize(width: 1000, height: 600), minimum: minimum) ==
      NSRect(x: -1300, y: 1200, width: 1000, height: 600))
    // Remembered on a bigger display: clamped to this one, never below the minimum.
    #expect(QuickTerminalController.frame(in: small, size: NSSize(width: 2000, height: 100), minimum: minimum) ==
      NSRect(x: 0, y: 100, width: 800, height: 300))
  }

  @Test("the quick terminal is its own permanent panel; the workspace window is untouched by summon and hide")
  func separatePanel() throws {
    let suite = "quick-terminal-panel.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let main = WorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); main.close(); panel.close() }
    controller.attach(to: main)
    controller.attach(panel: panel)
    main.setFrame(NSRect(x: 120, y: 80, width: 880, height: 640), display: false)
    main.makeKeyAndOrderFront(nil)
    let home = main.frame
    let style = main.styleMask
    let behavior = main.collectionBehavior
    let level = main.level

    // Permanent overlay identity, before the panel is ever shown.
    #expect(panel !== main)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(!main.styleMask.contains(.nonactivatingPanel))
    #expect(panel.level == .floating)
    #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
    #expect(main.canBecomeMain)

    controller.toggle()
    #expect(controller.isShown)
    #expect(panel.isVisible)
    #expect(main.isVisible, "the main window keeps its own visibility")
    let screen = try #require(panel.screen)
    #expect(panel.frame == QuickTerminalController.frame(
      in: screen.visibleFrame, size: nil, minimum: panel.minSize))
    #expect(main.frame == home)

    controller.toggle()
    #expect(!controller.isShown)
    #expect(!controller.isQuick)
    #expect(!panel.isVisible)
    #expect(main.isVisible)
    #expect(main.frame == home)
    // Everything the old overlay machinery used to save and restore is
    // simply never touched: style, collection behavior, level, frame.
    #expect(main.styleMask == style)
    #expect(main.collectionBehavior == behavior)
    #expect(main.level == level)
    // The panel's overlay character survives hiding: nothing re-styles it.
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.level == .floating)
    #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])

    // Repeated summons never touch the main window either.
    for _ in 0..<3 {
      controller.toggle()
      #expect(controller.isShown)
      controller.toggle()
      #expect(!controller.isShown)
    }
    #expect(main.frame == home)
    #expect(main.styleMask == style)
    #expect(main.collectionBehavior == behavior)
    #expect(main.level == level)
  }

  /// The workspace window with its full-screen machinery spied on: the
  /// summon must never ask it to enter or leave full screen. A test cannot
  /// run the real transition, and faking the style bit crashes AppKit.
  final class FullScreenSpyWindow: WorkspaceWindow {
    private(set) var fullScreenToggles = 0
    override func toggleFullScreen(_ sender: Any?) { fullScreenToggles += 1 }
  }

  @Test("summoning never asks the workspace window to leave full screen: no style churn, no exit machinery")
  func simulatedFullScreen() throws {
    let suite = "quick-terminal-fullscreen.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let main = FullScreenSpyWindow(hosting: Color.clear, autosaveName: nil)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); main.close(); panel.close() }
    controller.attach(to: main)
    controller.attach(panel: panel)
    main.setFrame(NSRect(x: 60, y: 60, width: 900, height: 620), display: false)
    main.makeKeyAndOrderFront(nil)
    let home = main.frame
    let style = main.styleMask

    controller.toggle()
    #expect(controller.isShown)
    controller.toggle()
    #expect(!controller.isShown)
    // The old path saved a Home, toggled full screen off and restored
    // styles. None of that exists anymore: the main window is not even
    // asked about its full-screen state.
    #expect(main.fullScreenToggles == 0)
    #expect(main.styleMask == style)
    #expect(main.frame == home)
  }

  @Test("Keep on Top is the main window's own setting; the panel floats whatever it says")
  func alwaysOnTopIndependence() throws {
    let suite = "quick-terminal-ontop.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let main = WorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); main.close(); panel.close() }
    controller.attach(to: main)
    controller.attach(panel: panel)
    #expect(main.level == .normal)
    #expect(panel.level == .floating)

    controller.alwaysOnTop = true
    #expect(main.level == .floating)
    #expect(panel.level == .floating, "the quick panel floats on its own terms")

    controller.alwaysOnTop = false
    #expect(main.level == .normal)
    #expect(panel.level == .floating)

    controller.toggle()
    #expect(controller.isShown)
    #expect(panel.level == .floating)
    controller.toggle()
    #expect(!controller.isShown)
    #expect(panel.level == .floating)
  }

  @Test("the panel's size is remembered on its own, here and across launches")
  func rememberedSize() throws {
    let suite = "quick-terminal-size.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    controller.attach(panel: panel)
    controller.toggle()
    let screen = try #require(panel.screen)
    #expect(panel.frame == QuickTerminalController.frame(in: screen.visibleFrame, size: nil, minimum: panel.minSize),
      "a display's top third until dragged: \(panel.frame) on \(screen.visibleFrame), minimum \(panel.minSize)")

    // A drag ends at 900×520, pulled down and to the right: that size is
    // the overlay's from now on, hung from the top again.
    let dragged = NSSize(width: 900, height: 520)
    panel.setFrame(
      NSRect(x: panel.frame.minX + 40, y: panel.frame.minY - 60, width: dragged.width, height: dragged.height),
      display: false)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: panel)
    controller.hide()
    controller.toggle()
    #expect(panel.frame == QuickTerminalController.frame(in: screen.visibleFrame, size: dragged, minimum: panel.minSize))
    #expect(panel.frame.size == dragged)
    #expect(panel.frame.maxY == screen.visibleFrame.maxY, "still a drop-down from the top")

    // A frame set by code is not a drag, and is not remembered.
    panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 1000, height: 600)), display: false)
    controller.hide()
    controller.toggle()
    #expect(panel.frame.size == dragged)
    controller.stop()

    // The next launch remembers it too.
    let next = QuickTerminalController(defaults: defaults)
    defer { next.stop() }
    next.attach(panel: panel)
    next.toggle()
    #expect(panel.frame.size == dragged)

    next.resetSize()
    #expect(defaults.object(forKey: "quickTerminal.width") == nil)
    #expect(panel.frame == QuickTerminalController.frame(in: screen.visibleFrame, size: nil, minimum: panel.minSize))
  }

  @Test("summoning and hiding starts no session and closes none")
  func summonCreatesNothing() throws {
    let suite = "quick-terminal-sessions.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tabs = TabSet(defaults: defaults)
    let controller = tabs.quickTerminal
    let main = WorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); main.close(); panel.close() }
    tabs.adopt(SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true))
    controller.attach(to: main)
    controller.attach(panel: panel)
    let count = tabs.tabs.count
    let selected = tabs.selected
    let workspaces = tabs.workspaces.count

    for _ in 0..<3 {
      controller.toggle()
      #expect(controller.isShown)
      controller.toggle()
      #expect(!controller.isShown)
    }
    #expect(tabs.tabs.count == count)
    #expect(tabs.selected == selected)
    #expect(tabs.workspaces.count == workspaces)
    #expect(tabs.tabs.first?.isLive == true, "hiding the summon closed nothing")
  }

  @Test("losing the key hides the panel on its own; the workspace window stays as it was")
  func resignHides() async throws {
    let suite = "quick-terminal-resign.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let main = WorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    let panel = ResignableQuickPanel(hosting: Color.clear)
    defer { controller.stop(); main.close(); panel.close() }
    controller.attach(to: main)
    controller.attach(panel: panel)
    main.setFrame(NSRect(x: 40, y: 40, width: 900, height: 620), display: false)
    main.makeKeyAndOrderFront(nil)
    let home = main.frame
    controller.autoHide = true

    controller.toggle()
    #expect(controller.isShown)
    panel.reportsKey = false
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!controller.isShown)
    #expect(!panel.isVisible)
    #expect(main.isVisible)
    #expect(main.frame == home)

    // Hiding is idempotent, and a disabled controller ignores the shortcut.
    controller.hide()
    controller.enabled = false
    controller.toggle()
    #expect(!controller.isShown)
  }

  @Test("the menu-bar mark opens the main window at its own frame, never the summoned panel")
  func statusItemRevealsMain() throws {
    let suite = "quick-terminal-statusitem.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let main = WorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); main.close(); panel.close() }
    controller.attach(to: main)
    controller.attach(panel: panel)
    main.setFrame(NSRect(x: 90, y: 70, width: 880, height: 640), display: false)
    main.makeKeyAndOrderFront(nil)
    let home = main.frame

    controller.toggle()
    #expect(controller.isShown)
    controller.statusItemClicked()
    #expect(!controller.isQuick)
    #expect(!panel.isVisible)
    #expect(main.isVisible)
    #expect(main.frame == home, "the menu bar opens the main window where it was")

    controller.statusItemClicked()
    #expect(main.frame == home)
    #expect(!controller.isQuick)
  }

  @Test("editing bindings updates the global registration while the panel is hidden")
  func editsWhileHidden() async throws {
    let suite = "quick-terminal-edit.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = KeyBindingStore(defaults: defaults)
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    let binding = KeyBinding("f18", [.control, .option, .command])
    let command = WorkspaceAction.quickTerminal.command
    try store.set(binding, for: command, slot: 0, commands: WorkspaceAction.allCases.map(\.command))
    controller.useBindings(store)
    controller.attach(panel: panel)
    controller.toggle()
    controller.hide()
    #expect(!panel.isVisible)
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
    #expect(status == noErr, "the chord the edit took back is free to register again")
    #expect(!panel.isVisible, "editing the shortcut never summons the panel")
  }

  @Test("stop unregisters the global shortcut, exactly once and without trouble twice")
  func stopUnregisters() throws {
    let suite = "quick-terminal-stop.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { panel.close() }
    let binding = KeyBinding("f17", [.control, .option, .command])
    controller.configure([binding])
    controller.attach(panel: panel)
    #expect(controller.hotKeys.count == 1)

    controller.stop()
    #expect(controller.hotKeys.isEmpty)
    var ref: EventHotKeyRef?
    defer { if let ref { UnregisterEventHotKey(ref) } }
    let code = try #require(binding.carbonKeyCode)
    let status = RegisterEventHotKey(UInt32(code), binding.carbonModifiers,
      EventHotKeyID(signature: 0x54455354, id: 102), GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive), &ref)
    #expect(status == noErr, "a stopped controller holds no hotkey registration")
    controller.stop()
    #expect(controller.hotKeys.isEmpty)
  }

  /// A stand-in for "another app was in front": any other running
  /// application. Its activation is never invoked; a recorder stands in.
  private func otherRunningApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
      $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
  }

  @Test("an explicit reveal of the main window never returns key to the app the summon took it from")
  func explicitRevealSuppressesFocusRestore() async throws {
    let suite = "quick-terminal-reveal-focus.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let main = WorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); main.close(); panel.close() }
    controller.attach(to: main)
    controller.attach(panel: panel)
    main.makeKeyAndOrderFront(nil)
    let other = try #require(otherRunningApp())
    controller.frontmostApplication = { other }
    var restores = 0
    controller.focusRestore = { _ in restores += 1 }

    controller.toggle()
    controller.showAsMainWindow()
    try await Task.sleep(for: .milliseconds(300))
    #expect(restores == 0, "the reveal decides where key goes; it must not be undone by a restore the hide scheduled")

    // A natural dismiss still returns key the same way it always did.
    controller.toggle()
    controller.hide()
    try await Task.sleep(for: .milliseconds(300))
    #expect(restores == 1)
  }

  @Test("a restore an earlier hide scheduled is dropped when the panel is summoned again first")
  func reSummonCancelsPendingRestore() async throws {
    let suite = "quick-terminal-resummon-focus.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let main = WorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); main.close(); panel.close() }
    controller.attach(to: main)
    controller.attach(panel: panel)
    main.makeKeyAndOrderFront(nil)
    let other = try #require(otherRunningApp())
    controller.frontmostApplication = { other }
    var restores = 0
    controller.focusRestore = { _ in restores += 1 }

    controller.toggle()
    controller.hide()
    controller.toggle()
    #expect(controller.isShown)
    try await Task.sleep(for: .milliseconds(300))
    #expect(restores == 0, "summoning again supersedes the pending restore; key stays with the panel")

    controller.hide()
    try await Task.sleep(for: .milliseconds(300))
    #expect(restores == 1)
  }

  @Test("an input source change that leaves the layout alone keeps the registration")
  func inputSourceChangeKeepsRegistration() throws {
    let suite = "quick-terminal-input-source.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    controller.configure([KeyBinding("f17", [.control, .option, .command])])
    controller.attach(panel: panel)
    let registered = controller.hotKeys
    #expect(registered.count == 1)
    controller.keyboardChanged()
    controller.keyboardChanged()
    #expect(controller.hotKeys == registered, "switching Pinyin on and off is not a new shortcut")
    #expect(controller.shortcutProblem == nil)
  }

  @Test("the shortcut follows the pointer's display, not the frontmost window")
  func screenChoice() {
    let primary = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    let portrait = NSRect(x: -1440, y: -1120, width: 1440, height: 2560)
    let screens = [primary, portrait]
    #expect(QuickTerminalController.screenIndex(of: NSPoint(x: 10, y: 10), screens: screens) == 0)
    #expect(QuickTerminalController.screenIndex(of: NSPoint(x: -10, y: 10), screens: screens) == 1)
    #expect(QuickTerminalController.screenIndex(of: NSPoint(x: -10, y: 1400), screens: screens) == 1)
    #expect(QuickTerminalController.screenIndex(of: NSPoint(x: -10, y: -1000), screens: screens) == 1)
    #expect(QuickTerminalController.screenIndex(of: NSPoint(x: 3000, y: 100), screens: screens) == nil)
    #expect(QuickTerminalController.screenIndex(of: .zero, screens: []) == nil)
    // On the primary, even while another display holds the frontmost window.
    #expect(QuickTerminalController.screenIndex(of: NSPoint(x: 100, y: 100), screens: screens) == 0)
  }

  @Test("region dialogs stay with the workspace window while the panel holds the front")
  func dialogAnchorOwnership() throws {
    let suite = "quick-terminal-anchor.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tabs = TabSet(defaults: defaults)
    let main = UUID()
    let panel = tabs.quickTerminal.panelID

    tabs.note(window: main, shown: true, key: true)
    #expect(tabs.presentsDialogs(main))

    // The panel takes the front: it sizes and answers, but the anchor —
    // and the dialog presenter — stay with the workspace window.
    tabs.note(window: panel, shown: true, key: true)
    #expect(tabs.frontWindow == panel)
    #expect(tabs.presentsDialogs(main), "the workspace window behind the panel keeps the anchor")
    #expect(!tabs.presentsDialogs(panel), "the panel never presents")

    // The panel hides and the workspace window is front again.
    tabs.note(window: panel, shown: false, key: false)
    #expect(tabs.presentsDialogs(main))
  }

  @Test("a TabSet's key bindings live in its own defaults, not the shared app preferences")
  func keyBindingsAreIsolated() throws {
    let suiteA = "quick-terminal-keys-a.\(UUID())"
    let suiteB = "quick-terminal-keys-b.\(UUID())"
    let defaultsA = try #require(UserDefaults(suiteName: suiteA))
    let defaultsB = try #require(UserDefaults(suiteName: suiteB))
    defer {
      defaultsA.removePersistentDomain(forName: suiteA)
      defaultsB.removePersistentDomain(forName: suiteB)
    }
    let a = TabSet(defaults: defaultsA)
    let b = TabSet(defaults: defaultsB)
    let chord = KeyBinding("f13", [.control, .option, .command])
    let command = WorkspaceAction.quickTerminal.command
    try a.keyBindings.set(chord, for: command, slot: 0, commands: WorkspaceAction.allCases.map(\.command))

    // Visible through the same suite; another set still reads the
    // factory default — the customization never reached it.
    #expect(KeyBindingStore(defaults: defaultsA).bindings(for: command).first == chord)
    #expect(KeyBindingStore(defaults: defaultsB).bindings(for: command).first == KeyBinding("`", .control))
    #expect(b.keyBindings.bindings(for: command).first == KeyBinding("`", .control))
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
}
#endif
