#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import TetherTestSupport
  import Tether
  import TetherPluginHost
  import TetherPluginKit

  @testable import TetherApp

  /// A legal key fact for two test-owned roots. Native children still take
  /// real AppKit focus; the remembered root becomes key again after its sheet
  /// leaves. No interaction state is assigned by this fixture.
  @MainActor
  final class TestWorkspaceFocus {
    private(set) weak var owner: NSWindow?
    weak var main: KeyedWindow?
    weak var quick: KeyedQuickPanel?

    static func link(main: KeyedWindow, quick: KeyedQuickPanel? = nil) {
      let focus = main.testFocus ?? TestWorkspaceFocus()
      focus.main = main
      main.testFocus = focus
      if let quick { focus.quick = quick; quick.testFocus = focus }
      if focus.owner == nil { main.makeKey() }
      focus.checkExclusive()
    }

    func isKey(_ root: NSWindow) -> Bool {
      owner === root && root.attachedSheet == nil
        && root.childWindows?.contains(where: { $0.isKeyWindow }) != true
    }

    func becameKey(_ root: NSWindow) {
      let previous = owner
      owner = root
      checkExclusive()
      guard previous !== root else { return }
      if let previous {
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: previous)
      }
      NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: root)
    }

    func orderedOut(_ root: NSWindow) {
      if owner === root {
        owner = nil
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: root)
      }
      NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: root)
      checkExclusive()
    }

    func checkExclusive() {
      #expect(!(main?.isKeyWindow == true && quick?.isKeyWindow == true),
        "a dual-host fixture must never report two key roots")
    }
  }

  /// A window that answers as the key window, which a test process cannot
  /// otherwise make one: the titlebar treats a click on a window in the
  /// background differently.
  ///
  /// A drag is counted rather than run: `performDrag` tracks the real mouse
  /// until its button comes up, and a test has no mouse to let go of.
  final class KeyedWindow: NSWindow {
    var testFocus: TestWorkspaceFocus?
    private(set) var drags = 0
    private(set) var zooms = 0
    private(set) var miniaturizes = 0

    override var isKeyWindow: Bool { testFocus?.isKey(self) ?? true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override func makeKey() {
      super.makeKey()
      testFocus?.becameKey(self)
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
      super.makeKeyAndOrderFront(sender)
      testFocus?.becameKey(self)
    }
    override func orderOut(_ sender: Any?) {
      super.orderOut(sender)
      testFocus?.orderedOut(self)
    }
    override func performDrag(with event: NSEvent) { drags += 1 }
    override func zoom(_ sender: Any?) { zooms += 1 }
    override func miniaturize(_ sender: Any?) { miniaturizes += 1 }

    static func make() -> KeyedWindow {
      let window = KeyedWindow(
        contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      return window
    }
  }

  /// The whole window, as the app shows it, over a library in a directory of
  /// its own and secrets that never reach the keychain.
  @MainActor
  struct HostedWorkspace {
    let window = KeyedWindow.make()
    let tabs: TabSet
    let interaction: WorkspaceInteraction
    private let directory: URL
    private let suite: String
    private let shortcutMonitor: Any?

    @MainActor
    init(terminals: Int, installGlobalShortcuts: Bool = false) throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let store = HostStore(
        location: directory.appending(path: "config"), secrets: MemorySecrets(),
        credentials: DeviceCredentialStore(secrets: MemorySecrets()),
        databaseURL: directory.appending(path: "identity.sqlite"))
      suite = "Tether.HostedWorkspace.\(UUID())"
      tabs = TabSet(defaults: UserDefaults(suiteName: suite)!)
      let registry = PluginRegistry()
      interaction = WorkspaceInteraction(
        tabs: tabs, store: store, registry: registry, secrets: MemorySecrets())
      tabs.quickTerminal.interaction = interaction
      for index in 0..<terminals {
        tabs.adopt(SessionTab(preview: .local, known: KnownHosts(), name: "Terminal \(index + 1)", live: true))
      }
      let routedTabs = tabs
      shortcutMonitor = installGlobalShortcuts ? MenuKeyEquivalents.install { event in
        MenuKeyEquivalents.dispatch(event, tabs: routedTabs, registry: registry)
      } : nil
      var installed: InstalledPlugins?
      window.contentView = NSHostingView(
        rootView: RootView(
          store: store, tabs: tabs, registry: registry, secrets: MemorySecrets(),
          plugins: PluginAPI(consent: DialogConsent()),
          installedPlugins: Binding(get: { installed }, set: { installed = $0 }),
          interaction: interaction)
          .environment(\.workspaceIsPrimary, false))
      window.orderFront(nil)
      Self.settle(1.5)
    }

    @MainActor
    func tearDown() {
      if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
      interaction.stop()
      tabs.closeAll()
      tabs.quickTerminal.stop()
      window.delegate = nil
      window.close()
      AppPresence.returnToDock()
      UserDefaults().removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }

    static func settle(_ seconds: TimeInterval) {
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Down and up at a point in window coordinates, the way a person's
    /// click arrives: through the window, not to a view.
    func click(at point: NSPoint, count: Int = 1) {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(
          NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!)
      }
      Self.settle(0.25)
    }
  }

  /// The tab strip is in the titlebar, under AppKit's own handling and above
  /// the split view's panes. A click is sent through the window, the way a
  /// person's arrives, rather than to the strip.
  @MainActor
  @Suite("Tab strip clicks", .serialized, .appKitEventLoop)
  struct TabStripClickTests {
    @Test("the plus beside the tab strip requests a new tab without dragging the window")
    func plusCreatesTab() throws {
      let hosted = try HostedWorkspace(terminals: 0)
      defer { hosted.tearDown() }
      let window = hosted.window
      let tabs = hosted.tabs
      let (strip, frames) = try catcher(in: window)
      let plus = try #require(frames.values.first, "the empty strip still exposes its add button")
      let point = windowPoint(plus.midX, plus.midY, in: strip)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
      }
      HostedWorkspace.settle(0.25)
      #expect(tabs.tabs.count == 1, "one button press opens exactly one session through the controller")
      #expect(tabs.intent == nil, "no second view consumer or stranded intent")
      #expect(hosted.interaction.effectiveHost == hosted.interaction.workspaceHostID)
      #expect(window.isVisible)
      #expect(window.drags == 0)
    }

    @Test("the main workspace's real new-tab chord opens exactly one session with local or global-plus-local routing",
      arguments: [false, true])
    func mainNewTabChord(globalAndLocal: Bool) throws {
      let hosted = try HostedWorkspace(terminals: 1, installGlobalShortcuts: globalAndLocal)
      defer { hosted.tearDown() }
      let count = hosted.tabs.tabs.count
      #expect(hosted.tabs.interaction === hosted.interaction)
      #expect(hosted.interaction.hostID(for: hosted.window) == hosted.interaction.workspaceHostID)
      #expect(hosted.window.isKeyWindow && hosted.window.attachedSheet == nil && NSApp.modalWindow == nil)
      #expect(hosted.interaction.shortcutsAllowed(in: hosted.interaction.workspaceHostID))
      #expect(hosted.tabs.canPerform(.newTab))
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: type, location: .zero,
          modifierFlags: [.command], timestamp: 0, windowNumber: hosted.window.windowNumber,
          context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17)))
      }
      #expect(hosted.tabs.tabs.count == count + 1)
      #expect(hosted.interaction.effectiveHost == hosted.interaction.workspaceHostID)
      #expect(hosted.window.isVisible)
    }

    /// The strip's scroll view takes the width the tabs do not need, and the
    /// catcher lies over all of it. A press there that misses every tab is a
    /// press on the titlebar, and a titlebar moves its window.
    @Test("a press on the strip beside the tabs drags the window")
    func emptyStripDrags() throws {
      let hosted = try HostedWorkspace(terminals: 2)
      defer { hosted.tearDown() }
      let selected = hosted.tabs.selectedWorkspaceID

      let (strip, frames) = try catcher(in: hosted.window)
      let end = try #require(frames.values.map(\.maxX).max())
      #expect(strip.bounds.width > end + 40, "the strip runs on past its last tab")
      let midY = try #require(frames.values.first).midY
      hosted.click(at: windowPoint(end + 30, midY, in: strip))

      #expect(hosted.window.drags == 1)
      #expect(hosted.tabs.selectedWorkspaceID == selected)
    }

    private func textField(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field.isEditable { return field }
      return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }

    private func catcher(in window: NSWindow) throws -> (NSView, [UUID: CGRect]) {
      let strip = try #require(window.contentView.flatMap(catcher(in:)))
      let frames =
        Mirror(reflecting: strip).children.first { $0.label == "frames" }?.value as? [UUID: CGRect] ?? [:]
      return (strip, frames)
    }

    /// SwiftUI frames are top-left; the strip may be either way up.
    private func windowPoint(_ x: CGFloat, _ y: CGFloat, in strip: NSView) -> NSPoint {
      strip.convert(NSPoint(x: x, y: strip.isFlipped ? y : strip.bounds.height - y), to: nil)
    }

    private func catcher(in view: NSView) -> NSView? {
      if String(describing: type(of: view)) == "Catcher" { return view }
      return view.subviews.lazy.compactMap(catcher(in:)).first
    }
  }
#endif
