#if os(macOS)
import AppKit
import Testing
import TetherPluginKit
import TetherTestSupport
@testable import TetherApp

@MainActor
private final class FeedbackDispatchFixture {
  /// Native window levels, with ordering/focus facts controlled by this test.
  final class Window: NSWindow {
    var orderedIn = false
    var keyed = false
    var minimized = false
    override var isVisible: Bool { orderedIn }
    override var isKeyWindow: Bool { keyed }
    override var isMiniaturized: Bool { minimized }
  }

  let suite = "Tether.WindowFeedbackTests.\(UUID())"
  let location = temporaryFile("hosts.json")
  let defaults: UserDefaults
  let registry: PluginRegistry
  let tabs: TabSet
  let interaction: WorkspaceInteraction
  let main: Window
  let quick: Window
  let quickID = UUID()
  var reveals = 0

  init(alwaysOnTop: Bool = false) {
    defaults = UserDefaults(suiteName: suite)!
    defaults.set(alwaysOnTop, forKey: "window.alwaysOnTop")
    defaults.set(false, forKey: "quickTerminal.enabled")
    defaults.set(false, forKey: "quickTerminal.menuBarIcon")
    tabs = TabSet(defaults: defaults)
    registry = PluginRegistry(defaults: defaults)
    let secrets = MemorySecrets()
    interaction = WorkspaceInteraction(tabs: tabs,
      store: HostStore(location: location, secrets: secrets), registry: registry, secrets: secrets)
    main = Window(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    quick = Window(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    main.isReleasedWhenClosed = false
    quick.isReleasedWhenClosed = false
    quick.level = .floating
    tabs.quickTerminal.interaction = interaction
    tabs.quickTerminal.attach(to: main)
    interaction.register(id: interaction.workspaceHostID, kind: .workspace, window: main)
    interaction.register(id: quickID, kind: .quick, window: quick)
    tabs.quickTerminal.workspaceReveal = { [weak self] window in
      guard let self else { return }
      #expect(window === self.main)
      self.reveals += 1
    }
  }

  func show(_ id: UUID) {
    let isMain = id == interaction.workspaceHostID
    main.keyed = isMain
    quick.keyed = !isMain
    let window = isMain ? main : quick
    window.orderedIn = true
    interaction.update(id: id, state: WorkspaceHostState(orderedIn: true, renderVisible: true))
  }

  func cleanUp() {
    interaction.stop()
    interaction.unregister(id: interaction.workspaceHostID)
    interaction.unregister(id: quickID)
    tabs.quickTerminal.workspaceReveal = nil
    tabs.quickTerminal.stop()
    tabs.closeAll()
    main.close(); quick.close()
    defaults.removePersistentDomain(forName: suite)
    removeDirectory(of: location)
  }
}

@MainActor
@Suite("Window feedback dispatch", .serialized, .appKitEventLoop)
struct WindowFeedbackDispatchTests {
  @Test("main completion reports the resulting on/off preference and native level")
  func mainToggleReportsFinalState() throws {
    let f = FeedbackDispatchFixture(); defer { f.cleanUp() }
    let main = f.interaction.workspaceHostID
    f.show(main)
    #expect(f.main.level == .normal)
    #expect(f.interaction.dispatch(.alwaysOnTop, from: main))
    #expect(f.tabs.quickTerminal.alwaysOnTop)
    #expect(f.defaults.bool(forKey: "window.alwaysOnTop"))
    #expect(f.main.level == .floating)
    let first = try #require(f.interaction.windowFeedback.message(for: main))
    #expect(first.title == "Always on Top")
    #expect(first.symbol == "pin.fill")
    #expect(!first.isStruckThrough)
    #expect(first.accessibilityLabel == "Always on Top: On")
    #expect(f.interaction.windowFeedback.message(for: f.quickID) == nil)
    #expect(f.interaction.dispatch(.alwaysOnTop, from: main))
    #expect(!f.tabs.quickTerminal.alwaysOnTop)
    #expect(!f.defaults.bool(forKey: "window.alwaysOnTop"))
    #expect(f.main.level == .normal)
    let second = try #require(f.interaction.windowFeedback.message(for: main))
    #expect(second.id != first.id)
    #expect(second.title == "Always on Top")
    #expect(second.title == first.title)
    #expect(second.symbol == "pin.slash")
    #expect(second.isStruckThrough)
    #expect(second.accessibilityLabel == "Always on Top: Off")
    #expect(f.quick.level == .floating)
    #expect(f.interaction.effectiveHost == main)
  }

  @Test("quick consumes on-top without changing preferences, levels, feedback, host, or revealing main",
    arguments: [false, true])
  func quickToggleIsConsumedNoOp(initial: Bool) throws {
    let f = FeedbackDispatchFixture(alwaysOnTop: initial); defer { f.cleanUp() }
    f.show(f.quickID)
    let mainLevel = f.main.level, quickLevel = f.quick.level
    #expect(f.interaction.dispatch(.alwaysOnTop, from: f.quickID))
    let chord = KeyBinding("t", [.control, .option])
    let catalog = KeyBindingCatalog.commands(registry: f.registry, tabs: f.tabs)
    try f.tabs.keyBindings.set(chord, for: WorkspaceAction.alwaysOnTop.command, slot: 0, commands: catalog)
    for repeated in [false, true] {
      #expect(handleWorkspaceShortcut(chord, repeated: repeated, editingText: false,
        interaction: f.interaction, hostID: f.quickID, registry: f.registry))
    }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [.control, .option], timestamp: 0, windowNumber: f.quick.windowNumber,
      context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
    #expect(MenuKeyEquivalents.dispatch(event, tabs: f.tabs, registry: f.registry) == nil,
      "the app monitor must consume the no-op before a view, menu, or terminal receives it")
    #expect(f.tabs.quickTerminal.alwaysOnTop == initial)
    #expect(f.defaults.bool(forKey: "window.alwaysOnTop") == initial)
    #expect(f.main.level == mainLevel)
    #expect(f.quick.level == quickLevel)
    #expect(f.reveals == 0)
    #expect(!f.main.isVisible)
    #expect(f.interaction.effectiveHost == f.quickID)
    #expect(f.interaction.lastEffectiveHost == f.quickID)
    #expect(f.interaction.windowFeedback.message(for: f.quickID) == nil)
    #expect(f.interaction.windowFeedback.message(for: f.interaction.workspaceHostID) == nil)
  }

  @Test("restoring startup state and direct property assignments never produce feedback")
  func startupAndPropertyAssignmentAreSilent() {
    let f = FeedbackDispatchFixture(alwaysOnTop: true); defer { f.cleanUp() }
    f.show(f.interaction.workspaceHostID)
    f.interaction.start()
    #expect(f.tabs.quickTerminal.alwaysOnTop)
    #expect(f.main.level == .floating)
    #expect(f.interaction.windowFeedback.message(for: f.interaction.workspaceHostID) == nil)
    f.tabs.quickTerminal.alwaysOnTop = false
    #expect(f.main.level == .normal)
    f.tabs.quickTerminal.alwaysOnTop = true
    #expect(f.main.level == .floating)
    #expect(f.interaction.windowFeedback.message(for: f.interaction.workspaceHostID) == nil)
    #expect(f.interaction.windowFeedback.message(for: f.quickID) == nil)
  }

  @Test("hide, miniaturize, unregister, and stop clear feedback without replay on return",
    arguments: ["hide", "miniaturize", "unregister", "stop"])
  func lifecycleClearsFeedback(operation: String) {
    let f = FeedbackDispatchFixture(); defer { f.cleanUp() }
    let main = f.interaction.workspaceHostID
    f.show(main)
    #expect(f.interaction.dispatch(.alwaysOnTop, from: main))
    f.interaction.windowFeedback.show(title: "Other window", symbol: "pin.fill", in: f.quickID)
    switch operation {
    case "hide":
      f.main.orderedIn = false
      NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: f.main)
    case "miniaturize":
      f.main.minimized = true
      NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: f.main)
    case "unregister": f.interaction.unregister(id: main)
    default: f.interaction.stop()
    }
    #expect(f.interaction.windowFeedback.message(for: main) == nil)
    #expect((f.interaction.windowFeedback.message(for: f.quickID) == nil) == (operation == "stop"))
    if operation == "unregister" { f.interaction.register(id: main, kind: .workspace, window: f.main) }
    f.main.minimized = false
    f.show(main)
    #expect(f.interaction.windowFeedback.message(for: main) == nil)
  }

  @Test("occlusion and focus changes preserve the original window's feedback without moving it")
  func occlusionDoesNotClearOrMoveFeedback() {
    let f = FeedbackDispatchFixture(); defer { f.cleanUp() }
    let main = f.interaction.workspaceHostID
    f.show(main)
    #expect(f.interaction.dispatch(.alwaysOnTop, from: main))
    let message = f.interaction.windowFeedback.message(for: main)
    f.interaction.update(id: main, state: WorkspaceHostState(orderedIn: true, renderVisible: false))
    f.show(f.quickID)
    #expect(f.interaction.windowFeedback.message(for: main) == message)
    #expect(f.interaction.windowFeedback.message(for: f.quickID) == nil)
  }
}
#endif
