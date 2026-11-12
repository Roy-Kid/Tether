#if os(macOS)
  import AppKit
  import SwiftUI
  import Tether
  import Testing
  import TetherPluginKit
  import TetherTestSupport
  @testable import TetherApp
  @testable import TetherUI

  /// What the quick terminal shows, decided from the shared TabSet: the
  /// selected terminal when there is one, a way back to the main window
  /// when a plugin stands where the terminal would be, and nothing at all
  /// when the selection is empty. Plugin content is never drawn here: a
  /// cached plugin web view cannot appear in two hosts.
  @MainActor
  @Suite("Quick Terminal Root", .serialized, .appKitEventLoop)
  struct QuickTerminalRootTests {
    @Test("the presentation follows the shared selection: terminal, plugin page, replacement, empty")
    func presentationMapping() throws {
      let suite = "quick-root-presentation.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      #expect(QuickPresentation.presentation(for: tabs) == .empty)

      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)
      #expect(QuickPresentation.presentation(for: tabs) == .terminal(live.id))

      // A plugin attachment standing in for the shell: offered back to
      // the main window, not drawn here and not silently switched away.
      let attachment = StubAttachment(subtitle: "tmux")
      attachment.isShowing = true
      live.attach(attachment, for: "test.plugin")
      #expect(QuickPresentation.presentation(for: tabs) == .pluginContent)

      // A plugin workspace page selected: the same offer.
      let workspace = StubWorkspace(title: "Files")
      tabs.openExtension(workspace, pluginID: "files", hostID: nil)
      #expect(QuickPresentation.presentation(for: tabs) == .pluginWorkspace)

      // Back to the terminal once nothing stands in for its shell: the
      // shared selection is what the panel shows.
      attachment.isShowing = false
      tabs.select(live.id)
      #expect(QuickPresentation.presentation(for: tabs) == .terminal(live.id))
    }

    @Test("the hosted root registers the panel with the shared tabs and starts nothing")
    func hostedLifecycle() throws {
      let suite = "quick-root-hosted.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)
      let controller = tabs.quickTerminal
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller))
      defer { controller.stop(); panel.close() }
      controller.attach(panel: panel)

      // As if the main window had just reported key: the panel's taking
      // key is what turns the workspace chords off.
      tabs.menuShortcuts = true
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      HostedWorkspace.settle(1.0)

      // The panel reported itself to the shared arbitration as a key
      // window — the state the sizing and palette answers read. Whether
      // the test process also resolves its occlusion is platform mood,
      // and not what these assertions stand on.
      #expect(tabs.keyWindows.count == 1)
      #expect(tabs.menuShortcuts == nil)
      // The root rendered what is selected; it started no session and
      // moved no selection of its own.
      #expect(tabs.tabs.count == 1)
      #expect(tabs.selected == live.id)
    }

    @Test("a plugin page in the panel offers the main window, and the offer reveals it")
    func hostedReveal() async throws {
      let suite = "quick-root-reveal.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)
      tabs.openExtension(StubWorkspace(title: "Files"), pluginID: "files", hostID: nil)
      let controller = tabs.quickTerminal
      let main = KeyedWindow.make()
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller))
      defer { controller.stop(); panel.close(); main.close() }
      controller.attach(to: main)
      controller.attach(panel: panel)

      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      HostedWorkspace.settle(1.0)
      #expect(QuickPresentation.presentation(for: tabs) == .pluginWorkspace)

      // SwiftUI draws the button as a focus-ring view inside its graphics
      // view, not an AppKit button. Click where it draws, the way a
      // person's click arrives: through the window.
      let offer = findView("_FocusRingView", in: panel.contentView!)
      #expect(offer != nil, "the panel offers the main window rather than plugin content")
      guard let offer else { return }

      click(offer)
      try await Task.sleep(for: .milliseconds(500))
      #expect(!panel.isVisible, "the offer steps the panel aside")
      #expect(main.isVisible, "and brings the main window forward")
      #expect(!controller.isQuick)
    }

    @Test("a tab with a pending question offers the main window; a down tab offers reconnect; a running one offers nothing")
    func offerMapping() throws {
      let suite = "quick-root-offer.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)
      #expect(QuickPresentation.mainWindowOffer(for: live) == nil)

      live.fail(TetherError.authenticationFailed(remaining: []))
      #expect(QuickPresentation.mainWindowOffer(for: live) == "Answer in the Main Window")

      live.setProblemAside()
      #expect(QuickPresentation.mainWindowOffer(for: live) == "Reconnect in the Main Window")

      // One preserved question: raising it again changes nothing, and the
      // quick never recreates or cancels the shared dialog request.
      live.raiseProblem()
      live.raiseProblem()
      #expect(live.problemRaised)
      #expect(QuickPresentation.mainWindowOffer(for: live) == "Answer in the Main Window")
    }

    @Test("a customized selection chord cycles the shared tabs in the panel, exactly once")
    func customizedCycleInQuick() throws {
      let suite = "quick-root-cycle.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      tabs.adopt(SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true))
      let page = try #require(tabs.workspaces.first?.id)
      tabs.adopt(SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 2", live: true), in: page)
      let chord = KeyBinding("p", [.control, .option, .command])
      try tabs.keyBindings.set(chord, for: WorkspaceAction.nextTerminal.command, slot: 0,
        commands: WorkspaceAction.allCases.map(\.command))
      let controller = tabs.quickTerminal
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller))
      defer { controller.stop(); panel.close() }
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      HostedWorkspace.settle(1.0)

      let first = try #require(tabs.selected)
      let other = try #require(tabs.tabs.first { $0.id != first }?.id)
      press("p", keyCode: 35, modifiers: [.control, .option, .command], in: panel)
      HostedWorkspace.settle(0.5)
      #expect(tabs.selected == other, "one chord moves the selection one terminal — a double dispatch would move it twice")
    }

    @Test("a chord that needs the main window reveals it, and the main window consumes the action exactly once")
    func newTabRevealsMainAndDelivers() async throws {
      // The real hosted workspace consumes intents the way the app does.
      let hosted = try HostedWorkspace(terminals: 1)
      let tabs = hosted.tabs
      let controller = tabs.quickTerminal
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller))
      defer {
        tabs.closeAll()
        controller.stop()
        panel.close()
        hosted.tearDown()
      }
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      HostedWorkspace.settle(1.0)

      let count = tabs.tabs.count
      press("t", keyCode: 17, modifiers: [.command], in: panel)
      // Consumed, not stranded: the intent is gone and exactly one tab
      // came of it — a second perform would show a second new tab.
      guard await waitFor({ tabs.tabs.count == count + 1 && tabs.intent == nil }, timeout: 10) else {
        Issue.record("the main window did not consume the action exactly once")
        return
      }
      #expect(tabs.frontWindow != controller.panelID, "the panel left the front arbitration before the action ran")
      try await Task.sleep(for: .milliseconds(500))
      #expect(!panel.isVisible, "the main window was revealed")
      #expect(hosted.window.isVisible, "and is on screen, holding the answer")
    }

    @Test("while the main window holds a blocking question, the panel takes no shortcuts and offers the way there")
    func sharedBlockerGatesQuick() async throws {
      let hosted = try HostedWorkspace(terminals: 1)
      let tabs = hosted.tabs
      let chord = KeyBinding("p", [.control, .option, .command])
      try tabs.keyBindings.set(chord, for: WorkspaceAction.nextTab.command, slot: 0,
        commands: WorkspaceAction.allCases.map(\.command))
      let controller = tabs.quickTerminal
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller))
      defer { controller.stop(); panel.close(); hosted.tearDown() }
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(Self.frameInVisibleDisplay(width: 800, height: 400), display: false)
      panel.orderFrontRegardless()
      panel.makeKey()
      HostedWorkspace.settle(1.0)
      let selected = try #require(tabs.selected)

      // The main window's own gate: a close confirmation holds it. Raise
      // it and wait for the actual dialog — the dismissal that follows
      // is asynchronous, and is awaited on every way out of the test.
      tabs.pendingClose = selected
      guard await waitFor({ self.captureOwnedDialog(on: hosted.window) != nil }, timeout: 10) else {
        Issue.record("the owned dialog never appeared. \(self.dialogDiagnostics(host: hosted.window))")
        await dismissOwnedDialog(tabs: tabs, host: hosted.window)
        return
      }
      do {
        guard await waitFor({
          !tabs.mainWindowShortcutsAllowed && !tabs.mainWindowInputAllowed
        }, timeout: 5) else {
          Issue.record("the main window never published its blocked gates")
          await dismissOwnedDialog(tabs: tabs, host: hosted.window)
          return
        }
        press("p", keyCode: 35, modifiers: [.control, .option, .command], in: panel)
        HostedWorkspace.settle(0.5)
        #expect(tabs.selected == selected, "selection must not move behind the main window's question")
        #expect(findView("_FocusRingView", in: panel.contentView!) != nil,
          "a blocked panel offers the way to the main window instead of a dead terminal")
      }
      await dismissOwnedDialog(tabs: tabs, host: hosted.window)
    }

    /// The dialog this test raised: the host's attached sheet, or the
    /// dialog windows stuck to it. Captured before cancellation so the
    /// dismissal is awaited on the actual windows.
    private struct OwnedDialog {
      let sheet: NSWindow?
      let children: [NSWindow]
    }

    private func captureOwnedDialog(on host: NSWindow) -> OwnedDialog? {
      if let sheet = host.attachedSheet { return OwnedDialog(sheet: sheet, children: []) }
      let children = host.childWindows ?? []
      return children.isEmpty ? nil : OwnedDialog(sheet: nil, children: children)
    }

    private func dialogGone(_ dialog: OwnedDialog, host: NSWindow) -> Bool {
      if let sheet = dialog.sheet {
        return !sheet.isVisible && sheet.sheetParent == nil && host.attachedSheet == nil
      }
      return (host.childWindows ?? []).isEmpty && dialog.children.allSatisfy { !$0.isVisible }
    }

    /// Cancel the blocker and wait for its dialog to actually withdraw —
    /// the chain (onChange → cancel → a MainActor task → endSheet) is
    /// async, and the AppKit turn serializes test bodies, not tasks
    /// still outstanding. Runs on every exit, so the host never closes
    /// with the question on screen.
    private func dismissOwnedDialog(tabs: TabSet, host: NSWindow) async {
      let dialog = captureOwnedDialog(on: host)
      tabs.cancelClose()
      guard let dialog else { return }
      guard await waitFor({ self.dialogGone(dialog, host: host) }, timeout: 10) else {
        Issue.record("the owned dialog never withdrew. \(self.dialogDiagnostics(host: host))")
        return
      }
    }

    /// Fixture state for a failure report: this fixture's own windows
    /// and the app's modal state — no terminal contents.
    private func dialogDiagnostics(host: NSWindow) -> String {
      "host sheet=\(host.attachedSheet != nil) children=\(host.childWindows?.count ?? 0) " +
        "host visible=\(host.isVisible) app hidden=\(NSApp.isHidden) " +
        "modal=\(NSApp.modalWindow != nil) app sheets=\(NSApp.windows.filter { $0.sheetParent != nil }.count)"
    }

    /// A frame inside an actually visible display — absolute points like
    /// (100, 100) can be off-screen on machines whose displays sit at
    /// negative origins.
    private static func frameInVisibleDisplay(width: CGFloat, height: CGFloat) -> NSRect {
      let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
      return NSRect(
        x: visible.minX + max(20, (visible.width - width) / 2),
        y: visible.minY + max(20, (visible.height - height) / 2),
        width: min(width, visible.width), height: min(height, visible.height)).integral
    }

    /// Down and up in a window, the way the monitors see them: through
    /// the application, not addressed to a view.
    private func press(_ character: String, keyCode: UInt16,
      modifiers: NSEvent.ModifierFlags, in window: NSWindow) {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: character,
          charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode)!
        NSApp.sendEvent(event)
      }
    }

    /// A main-window surface whose front-ness tracks the shared
    /// arbitration: `@Bindable`, so it re-reads `TabSet.isFront` when the
    /// arbitration changes instead of freezing the value it had when the
    /// hosting view was built.
    private struct HostedMainSurface: View {
      @Bindable var tabs: TabSet
      let tab: SessionTab
      let windowID: UUID

      var body: some View {
        SessionView(tab: tab)
          .environment(\.isFrontWindow, tabs.isFront(windowID))
      }
    }

    /// A tab with a real local shell behind it and a main-window surface,
    /// drawn alone first so its renderer presents and acknowledges before
    /// the panel exists; `summonPanel()` then adds the quick root over
    /// it. No credentials, no network: the shell is this machine's.
    /// Both phases await the real preconditions the renderer and the
    /// arbitration read — visibility, occlusion, front, a sized grid and
    /// a presented first frame — and fail at the fixture, with their own
    /// state in the report, when the environment never provides them.
    @MainActor
    final class FramedPair {
      let tab: SessionTab
      let tabs: TabSet
      let controller: QuickTerminalController
      let main: KeyedWindow
      let mainID: UUID
      /// The grid the main window's surface sized the session to; the
      /// panel taking the front must move it to its own.
      private var mainColumns: UInt32?
      var panel: KeyedQuickPanel?
      private(set) var panelGPU: TerminalGPUView?

      init(defaults: UserDefaults) async throws {
        tabs = TabSet(defaults: defaults)
        let tab = SessionTab(host: .local, password: "", known: KnownHosts(), name: "Terminal 1")
        self.tab = tab
        tabs.adopt(tab)
        tab.setPublishesFrames(true)
        guard await QuickTerminalRootTests.waitFor({ tab.frame != nil }, timeout: 15) else {
          tabs.closeAll()
          Issue.record("the local shell did not produce a frame")
          throw CancellationError()
        }
        controller = tabs.quickTerminal
        mainID = UUID()
        main = KeyedWindow.make()
        main.setFrame(QuickTerminalRootTests.frameInVisibleDisplay(width: 900, height: 600), display: false)
        main.contentView = NSHostingView(rootView: HostedMainSurface(tabs: tabs, tab: tab, windowID: mainID))
        main.orderFrontRegardless()
        tabs.note(window: mainID, shown: true, key: true)
        // The main surface drives the size while it is front.
        guard await QuickTerminalRootTests.waitFor({ tab.frame?.columns != nil }, timeout: 10) else {
          Issue.record("the main surface never sized the session. \(self.readinessReport(panel: nil))")
          close()
          throw CancellationError()
        }
        mainColumns = tab.frame?.columns
        HostedWorkspace.settle(1.0)
      }

      /// The quick panel over the main window, as the shortcut would —
      /// ordered regardless, like the production summon. Returns once
      /// the panel is what the measurements assume: on screen and called
      /// visible by the window server, holding the front of the shared
      /// arbitration, the session sized to its grid, and its renderer
      /// having presented a first frame.
      func summonPanel() async throws {
        guard panel == nil else { return }
        let panel = KeyedQuickPanel(
          hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller))
        self.panel = panel
        controller.attach(to: main)
        controller.attach(panel: panel)
        panel.setFrame(QuickTerminalRootTests.frameInVisibleDisplay(width: 700, height: 320), display: false)
        panel.orderFrontRegardless()
        tabs.note(window: controller.panelID, shown: true, key: true)
        let appShown = await QuickTerminalRootTests.waitFor({ !NSApp.isHidden }, timeout: 5)
        let panelVisible = await QuickTerminalRootTests.waitFor({
          panel.isVisible && !panel.isMiniaturized
            && panel.occlusionState.contains(.visible)
        }, timeout: 15)
        let panelFront = await QuickTerminalRootTests.waitFor(
          { self.tabs.frontWindow == self.controller.panelID }, timeout: 10)
        let panelSized = await QuickTerminalRootTests.waitFor({
          self.tab.frame?.columns != nil && self.tab.frame?.columns != self.mainColumns
        }, timeout: 10)
        let ready = appShown && panelVisible && panelFront && panelSized
        guard ready else {
          Issue.record("fixture: the panel never became ready. \(self.readinessReport(panel: panel))")
          throw CancellationError()
        }
        guard let gpu = QuickTerminalRootTests.gpuView(in: panel.contentView!),
          await QuickTerminalRootTests.waitFor({ gpu.submittedFrames > 0 }, timeout: 15)
        else {
          Issue.record("fixture: the panel's surface never presented. \(self.readinessReport(panel: panel))")
          throw CancellationError()
        }
        panelGPU = gpu
        HostedWorkspace.settle(1.0)
      }

      /// This fixture's own state when a readiness wait fails — windows,
      /// occlusion, modal state, front, grid, GPU — no terminal contents.
      func readinessReport(panel: KeyedQuickPanel?) -> String {
        var parts: [String] = []
        if let panel {
          parts.append("panel visible=\(panel.isVisible) miniaturized=\(panel.isMiniaturized) " +
            "occlusion=\(panel.occlusionState.rawValue) frame=\(panel.frame)")
        }
        parts.append("main visible=\(main.isVisible) occlusion=\(main.occlusionState.rawValue)")
        parts.append("app hidden=\(NSApp.isHidden) modal=\(NSApp.modalWindow != nil) " +
          "main sheet=\(main.attachedSheet != nil) panel sheet=\(panel?.attachedSheet != nil)")
        parts.append("front=\(String(describing: tabs.frontWindow)) panelID=\(controller.panelID) " +
          "mainID=\(mainID) columns=\(String(describing: tab.frame?.columns))")
        parts.append("gpu=\(panelGPU?.submittedFrames ?? -1)")
        return parts.joined(separator: "; ")
      }

      func close() {
        tabs.closeAll()
        controller.stop()
        main.close()
        panel?.close()
      }
    }

    /// The shared renderer's view inside a surface, for per-surface
    /// frame counts. What this counts is frames presented to the GPU,
    /// not pixels — model-level evidence that a surface drew.
    private static func gpuView(in view: NSView) -> TerminalGPUView? {
      if let gpu = view as? TerminalGPUView { return gpu }
      for subview in view.subviews {
        if let found = Self.gpuView(in: subview) { return found }
      }
      return nil
    }

    @Test("the quick surface keeps presenting whole frames after the main surface's acknowledgment",
      .enabled(if: TerminalSession.isLocalAvailable))
    func mainAckDoesNotStarveQuick() async throws {
      let suite = "quick-root-frames.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let pair = try await FramedPair(defaults: defaults)
      defer { pair.close() }
      let tab = pair.tab

      // Frames have reached the main window's surface by now; its
      // `onPresented` acknowledges the epoch it drew (`SessionView`).
      // Consume the shared damage exactly as that acknowledgment does —
      // before the panel ever draws. (The test process's own occluded
      // window is not trusted to present; the acknowledgment call is the
      // seam both sides share.)
      guard await waitFor({ tab.damageEpoch > 0 }, timeout: 15) else {
        Issue.record("the session never produced a frame")
        return
      }
      tab.acknowledgeDamage(epoch: tab.damageEpoch)

      try await pair.summonPanel()
      let quickGPU = try #require(Self.gpuView(in: pair.panel!.contentView!))
      let presented = quickGPU.submittedFrames
      let epoch = tab.damageEpoch
      tab.send(.paste("echo quick-ack"))
      tab.send(.key(.enter))
      // Both the model and the panel's own renderer move: the quick
      // reads whole frames (`dirtyRows: nil`), so the acknowledged
      // (consumed) damage cannot suppress its next draw.
      guard await waitFor({ quickGPU.submittedFrames > presented && tab.damageEpoch > epoch }, timeout: 10)
      else {
        Issue.record("the quick surface stopped presenting after the main surface's acknowledgment")
        return
      }
      #expect(tab.frame != nil)
    }

    @Test("with the workspace window hidden, the panel's surface keeps presenting",
      .enabled(if: TerminalSession.isLocalAvailable))
    func hiddenMainOutputContinues() async throws {
      let suite = "quick-root-hidden.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let pair = try await FramedPair(defaults: defaults)
      defer { pair.close() }
      try await pair.summonPanel()
      let quickGPU = try #require(Self.gpuView(in: pair.panel!.contentView!))

      pair.main.orderOut(nil)
      let presented = quickGPU.submittedFrames
      pair.tab.send(.paste("echo quick-hidden"))
      pair.tab.send(.key(.enter))
      guard await waitFor({ quickGPU.submittedFrames > presented }, timeout: 10) else {
        Issue.record("hiding the workspace window stopped the panel's surface from presenting")
        return
      }
      #expect(!pair.main.isVisible)
    }

    @Test("the front surface sizes the session, and the other reapplies its own size when front again",
      .enabled(if: TerminalSession.isLocalAvailable))
    func frontSizingHandoff() async throws {
      let suite = "quick-root-sizing.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let pair = try await FramedPair(defaults: defaults)
      defer { pair.close() }
      try await pair.summonPanel()
      let tab = pair.tab
      let tabs = pair.tabs

      // By now the panel has reported itself shown and key, holds the
      // front, and has sized the session to its own grid — that is the
      // front-sizing half of the contract.
      guard tab.frame?.columns != nil, tabs.frontWindow == pair.controller.panelID else {
        Issue.record("the panel in front never sized the session")
        return
      }
      let quickColumns = try #require(tab.frame?.columns)
      // The main window takes the front back: it reapplies the size it
      // kept while the panel was in front.
      tabs.note(window: pair.mainID, shown: true, key: true)
      guard await waitFor({ tab.frame.map { $0.columns > quickColumns + 5 } ?? false }, timeout: 10) else {
        Issue.record("the main window in front never took its size back")
        return
      }
      let mainColumns = try #require(tab.frame?.columns)
      // And the panel, front again, takes its size back.
      tabs.note(window: pair.controller.panelID, shown: true, key: true)
      guard await waitFor({ tab.frame.map { $0.columns < mainColumns - 5 } ?? false }, timeout: 10) else {
        Issue.record("the panel in front never reapplied its own size")
        return
      }
    }

    private func waitFor(_ condition: @MainActor () -> Bool, timeout: TimeInterval) async -> Bool {
      await Self.waitFor(condition, timeout: timeout)
    }

    private static func waitFor(_ condition: @MainActor () -> Bool, timeout: TimeInterval) async -> Bool {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return condition()
    }

    private func findView(_ className: String, in view: NSView) -> NSView? {
      if String(describing: type(of: view)) == className { return view }
      for subview in view.subviews {
        if let found = findView(className, in: subview) { return found }
      }
      return nil
    }

    /// Down and up at the middle of a view, the way a person's click
    /// arrives: through the window, not to the view.
    private func click(_ view: NSView) {
      guard let window = view.window else { return }
      let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
      }
    }
  }
#endif
