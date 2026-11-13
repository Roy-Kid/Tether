#if os(macOS)
  import AppKit
  import SwiftUI
  import Tether
  import Testing
  import TetherPluginKit
  import TetherPluginHost
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
    @Test("a visible vertical main strip stays leading after quick summon, new tab, local toggle and hide",
      .enabled(if: TerminalSession.isLocalAvailable))
    func verticalMainStripSurvivesQuickActions() async throws {
      let suite = "quick-root-vertical-main-retention.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      let file = temporaryFile("hosts.json")
      defaults.set(true, forKey: TabBarPreference.key)
      defaults.set(true, forKey: "quickTerminal.tabBarVisible")
      defaults.set(TabLayout.vertical.rawValue, forKey: TabLayout.preferenceKey)
      defaults.set(false, forKey: "quickTerminal.menuBarIcon")
      let secrets = MemorySecrets()
      let tabs = TabSet(defaults: defaults)
      let registry = PluginRegistry(defaults: defaults)
      let store = HostStore(location: file, secrets: secrets)
      let interaction = WorkspaceInteraction(tabs: tabs, store: store, registry: registry, secrets: secrets)
      let controller = tabs.quickTerminal
      controller.interaction = interaction
      controller.frontmostApplication = { nil }
      tabs.adopt(SessionTab(preview: .local, known: tabs.known, name: "Main preview", live: true))
      let main = KeyedWindow.make()
      main.contentView = NSHostingView(rootView:
        RootView(store: store, tabs: tabs, registry: registry, secrets: secrets,
          plugins: PluginAPI(consent: DialogConsent()), installedPlugins: .constant(nil), interaction: interaction)
          .environment(\.workspaceIsPrimary, false)
          .defaultAppStorage(defaults))
      let panel = KeyedQuickPanel(hosting:
        QuickTerminalRoot(tabs: tabs, registry: registry, controller: controller, interaction: interaction)
          .defaultAppStorage(defaults))
      defer {
        interaction.stop(); tabs.closeAll(); controller.stop()
        main.delegate = nil; panel.close(); main.close()
        defaults.removePersistentDomain(forName: suite); removeDirectory(of: file)
      }
      TestWorkspaceFocus.link(main: main, quick: panel)
      controller.attach(to: main)
      controller.attach(panel: panel)
      main.setFrame(Self.frameInVisibleDisplay(width: 1000, height: 650), display: false)
      main.orderFrontRegardless()
      main.makeKey()
      let content = try #require(main.contentView)
      @MainActor func leadingStripExists() -> Bool {
        let strips = catchers(in: content)
        guard strips.count == 1, let strip = strips.first else { return false }
        let frame = strip.convert(strip.bounds, to: nil)
        return abs(frame.minX) < 0.5 && frame.width > 0 && frame.width < content.bounds.width / 2
          && frame.height > frame.width
      }
      try #require(await Self.waitFor({ leadingStripExists() }, timeout: 10),
        "the main window must initially render a real leading vertical strip")
      controller.toggle()
      try #require(await Self.waitFor({ panel.isVisible && interaction.effectiveHost == controller.panelID }, timeout: 10))
      #expect(panel.isKeyWindow && !main.isKeyWindow)
      let count = tabs.tabs.count
      press("t", keyCode: 17, modifiers: [.command], in: panel)
      #expect(tabs.tabs.count == count + 1 && panel.isVisible)
      try tabs.keyBindings.set(KeyBinding("b", [.control, .option, .command]),
        for: WorkspaceAction.toggleTabBar.command, slot: 0, commands: WorkspaceAction.allCases.map(\.command))
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      try #require(await Self.waitFor({ catchers(in: panel.contentView!).isEmpty }, timeout: 10))
      #expect(leadingStripExists(), "quick's own toggle must not remove main's rendered sidebar")
      controller.hide()
      try #require(await Self.waitFor({
        !panel.isVisible && interaction.effectiveHost == interaction.workspaceHostID && leadingStripExists()
      }, timeout: 10), "returning to main must retain its actual leading strip")
      #expect(main.isKeyWindow && !panel.isKeyWindow)
      #expect(defaults.bool(forKey: TabBarPreference.key))
      #expect(defaults.string(forKey: TabLayout.preferenceKey) == TabLayout.vertical.rawValue)
    }

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

    @Test("the hosted root registers the panel as a host and starts nothing")
    func hostedLifecycle() throws {
      let suite = "quick-root-hosted.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer { controller.stop(); panel.close() }
      controller.attach(panel: panel)

      // The report the panel's own reporter would deliver: key within the
      // host. What the sizing and palette answers read is the
      // interaction's effective host.
      interaction.register(id: controller.panelID, kind: .quick, window: panel)
      interaction.update(id: controller.panelID, state: WorkspaceHostState(
        orderedIn: true, renderVisible: true, keyWithinHost: true))
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      HostedWorkspace.settle(1.0)

      #expect(interaction.effectiveHost == controller.panelID)
      // The root rendered what is selected; it started no session and
      // moved no selection of its own.
      #expect(tabs.tabs.count == 1)
      #expect(tabs.selected == live.id)
    }

    @Test("one chrome row — the shared tab strip: the terminal fills what it leaves, and no row of the panel's own",
      .enabled(if: TerminalSession.isLocalAvailable))
    func tabStripGeometry() async throws {
      let suite = "quick-root-chrome.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let pair = try await FramedPair(defaults: defaults)
      defer { pair.close() }
      try await pair.summonPanel()
      let panel = try #require(pair.panel)
      let content = try #require(panel.contentView)

      // One row of chrome, the shared tab strip itself: at the window's
      // top, one tab high. A second strip would mean the root grew a row
      // of its own; laid out under the titlebar's safe-area inset the
      // whole stack would sit one titlebar-row lower instead.
      let strips = catchers(in: content)
      #expect(strips.count == 1, "exactly one tab strip")
      let stripFrame = try #require(strips.first).convert(strips.first!.bounds, to: nil)
      #expect(stripFrame.maxY == content.bounds.height, "the strip's top is the window's top")
      #expect(stripFrame.height == Chrome.tab, "one tab high")
      // The terminal fills exactly what the strip leaves — no empty
      // title row above it, no gap below it.
      let gpu = try #require(Self.gpuView(in: content))
      let gpuFrame = gpu.convert(gpu.bounds, to: nil)
      #expect(gpuFrame.maxY == content.bounds.height - Chrome.tab, "the terminal's top is the strip's bottom")
      #expect(gpuFrame.height == content.bounds.height - Chrome.tab, "the terminal fills what the strip leaves")
      // The native titlebar stays invisible: dismissal is hide-only and
      // the panel is not miniaturizable or zoomable.
      for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        #expect(panel.standardWindowButton(button)?.isHidden == true, "the \(button) widget stays hidden")
      }

      // The shared strip preference is the panel's too: with the bar off
      // the terminal fills the whole window again.
      pair.tabs.toggleTabBar()
      guard await Self.waitFor({
        guard let gpu = Self.gpuView(in: content) else { return false }
        return gpu.convert(gpu.bounds, to: nil).height == content.bounds.height
      }, timeout: 10) else {
        Issue.record("hiding the strip did not give the terminal the whole window")
        return
      }
    }

    @Test("a click on a tab in the panel's strip selects it on the shared TabSet")
    func stripClickSelectsTab() throws {
      let suite = "quick-root-strip-click.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      let first = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      let second = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 2", live: true)
      tabs.adopt(first)
      tabs.adopt(second)
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer { controller.stop(); panel.close() }
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      HostedWorkspace.settle(1.0)
      tabs.select(first.id)
      #expect(tabs.selected == first.id)

      // A press on the second chip, through the window the way a person's
      // click arrives, moves the shared selection — the main window's
      // strip shows the same tab selected.
      let strip = try #require(catcher(in: panel.contentView!))
      let chip = try #require(frames(strip)[second.id], "the second terminal is a chip in the strip")
      click(at: windowPoint(chip.midX, chip.midY, in: strip), in: panel)
      #expect(tabs.selected == second.id, "a click in the panel's strip selects on the shared TabSet")
    }

    @Test("the strip's add in the panel opens the tab there: the panel stays up and stays effective")
    func stripPlusOpensTabInPanel() async throws {
      let hosted = try HostedWorkspace(terminals: 1)
      let tabs = hosted.tabs
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer {
        tabs.closeAll()
        controller.stop()
        panel.close()
        hosted.tearDown()
      }
      TestWorkspaceFocus.link(main: hosted.window, quick: panel)
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      // The report the panel's own reporter would deliver.
      interaction.register(id: controller.panelID, kind: .quick, window: panel)
      HostedWorkspace.settle(1.0)

      let strip = try #require(catcher(in: panel.contentView!))
      let chipIDs = Set(tabs.tabs.map(\.id))
      let plus = try #require(
        frames(strip).first { !chipIDs.contains($0.key) }?.value,
        "the strip exposes its add button beside the tabs")
      let count = tabs.tabs.count
      click(at: windowPoint(plus.midX, plus.midY, in: strip), in: panel)
      // The new contract: the tab opens where it was asked, and the panel
      // does not step aside — still up, still the effective host.
      guard await Self.waitFor({
        tabs.tabs.count == count + 1 && panel.isVisible
          && interaction.effectiveHost == controller.panelID
      }, timeout: 15) else {
        let state = "count=\(tabs.tabs.count)/\(count + 1); panelVisible=\(panel.isVisible); " +
          "effective=\(String(describing: interaction.effectiveHost))"
        Issue.record("the new tab did not land in the panel: \(state)")
        return
      }
    }

    @Test("the strip's close presents one native panel question; its answer settles once and deferred hide waits for gone",
      arguments: [false, true])
    func stripCloseAsksInPanel(confirm: Bool) async throws {
      let hosted = try HostedWorkspace(terminals: 2)
      let tabs = hosted.tabs
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer {
        interaction.stop()
        tabs.closeAll()
        controller.stop()
        panel.close()
        hosted.tearDown()
      }
      TestWorkspaceFocus.link(main: hosted.window, quick: panel)
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(Self.frameInVisibleDisplay(width: 800, height: 400), display: false)
      panel.orderFrontRegardless()
      panel.makeKey()
      interaction.register(id: controller.panelID, kind: .quick, window: panel)
      HostedWorkspace.settle(1.0)
      interaction.start()
      let presentations = SheetCount()
      let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willBeginSheetNotification, object: panel, queue: .main
      ) { _ in MainActor.assumeIsolated { presentations.value += 1 } }
      defer { NotificationCenter.default.removeObserver(observer) }
      do {
        let strip = try #require(catcher(in: panel.contentView!))
        let selected = try #require(tabs.selected)
        let chip = try #require(frames(strip)[selected], "the selected terminal is a chip in the strip")
        let count = tabs.tabs.count
        let closedCount = tabs.closedTabs.count
        click(at: windowPoint(chip.maxX - 4, chip.midY, in: strip), in: panel)
        try #require(await Self.waitFor({
          self.captureOwnedDialog(on: panel) != nil && presentations.value == 1
        }, timeout: 10), "the controller must present a native question on the panel: \(dialogDiagnostics(host: panel))")
        let owned = try #require(captureOwnedDialog(on: panel))
        let child = try #require(owned.sheet ?? owned.children.first)
        #expect(child.isVisible)
        #expect(child.sheetParent === panel || child.parent === panel)
        #expect(hosted.window.attachedSheet == nil && hosted.window.childWindows?.isEmpty != false)
        #expect(tabs.pendingClose == selected && tabs.tabs.count == count)
        #expect(interaction.presentationOwner == controller.panelID)
        #expect(interaction.effectiveHost == controller.panelID && panel.isVisible)

        // Re-requesting while blocked is declined, not a second presentation.
        interaction.requestCloseFromTabBar(selected, from: controller.panelID)
        #expect(!interaction.dispatch(.closeTerminal, from: controller.panelID))
        controller.hide()
        #expect(panel.isVisible, "an explicit hide cannot remove the owner underneath its native question")
        #expect(interaction.presentationOwner == controller.panelID)
        let title = confirm ? tabs.pendingCloseVerb : "Cancel"
        let button = try #require(child.contentView.flatMap { view in
          self.nativeButtons(in: view).first { $0.title == title }
        }, "the native question exposes its \(title) action")
        button.performClick(nil)
        if !dialogGone(owned, host: panel) {
          #expect(interaction.presentationOwner == controller.panelID,
            "answering is not native dismissal; the lease must still be held")
          #expect(panel.isVisible)
        }
        try #require(await Self.waitFor({
          self.dialogGone(owned, host: panel) && !interaction.hasBlockingPresentation && !panel.isVisible
        }, timeout: 10), "native gone must release the lease and execute the deferred hide")
        #expect(tabs.pendingClose == nil)
        #expect(tabs.tabs.count == count - (confirm ? 1 : 0))
        #expect(tabs.tabs.contains { $0.id == selected } == !confirm)
        #expect(tabs.closedTabs.count == closedCount + (confirm ? 1 : 0), "the domain close happens exactly once")
        #expect(presentations.value == 1)
        #expect(hosted.window.attachedSheet == nil && hosted.window.childWindows?.isEmpty != false)
      } catch {
        await dismissOwnedDialog(tabs: tabs, host: panel)
        throw error
      }
      await dismissOwnedDialog(tabs: tabs, host: panel)
    }

    @MainActor private final class SheetCount { var value = 0 }

    private func nativeButtons(in view: NSView) -> [NSButton] {
      let own = (view as? NSButton).map { [$0] } ?? []
      return own + view.subviews.flatMap { nativeButtons(in: $0) }
    }

    @Test("a split asked in the panel shows both panes in the panel",
      .enabled(if: TerminalSession.isLocalAvailable))
    func splitShowsInPanel() async throws {
      let suite = "quick-root-split.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      // A preview has no ScreenFrame, hence no GPU surface to split. Start
      // with the same frame-ready local fixture used by the sizing tests.
      let pair = try await FramedPair(defaults: defaults)
      defer { pair.close() }
      try await pair.summonPanel()
      let tabs = pair.tabs
      let interaction = pair.interaction
      let controller = pair.controller
      let panel = try #require(pair.panel)
      let count = tabs.tabs.count

      _ = interaction.dispatch(.splitRight, from: controller.panelID)
      guard await Self.waitFor({
        tabs.workspaceSplit != nil && tabs.tabs.count == count + 1 && panel.isVisible
          && Self.gpuViews(in: panel.contentView!).count == 2
      }, timeout: 10) else {
        let state = "split=\(String(describing: tabs.workspaceSplit)); " +
          "panes=\(Self.gpuViews(in: panel.contentView!).count)"
        Issue.record("the split did not show both panes in the panel: \(state)")
        return
      }
    }

    @Test("the palette and the host picker present on the effective panel, which stays up")
    func paletteAndHostPickerPresentInPanel() async throws {
      let hosted = try HostedWorkspace(terminals: 1)
      let tabs = hosted.tabs
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer {
        tabs.closeAll()
        controller.stop()
        panel.close()
        hosted.tearDown()
      }
      TestWorkspaceFocus.link(main: hosted.window, quick: panel)
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      interaction.register(id: controller.panelID, kind: .quick, window: panel)
      HostedWorkspace.settle(1.0)

      _ = interaction.dispatch(.commandMenu, from: controller.panelID)
      guard await Self.waitFor({
        panel.isVisible && Self.editableFields(in: panel.contentView!).isEmpty == false
      }, timeout: 10) else {
        Issue.record("the palette did not present on the panel")
        return
      }
      tabs.palette = nil
      _ = interaction.dispatch(.changeHost, from: controller.panelID)
      guard await Self.waitFor({
        panel.isVisible
          && Self.editableFields(in: panel.contentView!).contains {
            $0.placeholderString == "Find a host…"
          }
      }, timeout: 10) else {
        Issue.record("the host picker did not present on the panel")
        return
      }
    }

    @Test("a click on the selected tab's accessory in the panel hands it to the main window, and never opens it here")
    func stripAccessoryHandsToMain() async throws {
      let suite = "quick-root-accessory.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)
      let stub = StubAttachment(subtitle: "tmux")
      live.attach(stub, for: "test.plugin")
      tabs.accessories = [PluginAccessory(
        id: "test.plugin", title: "Stub", accessory: TabAccessory(symbol: "", name: "Stub"))]
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let main = KeyedWindow.make()
      interaction.register(id: interaction.workspaceHostID, kind: .workspace, window: main)
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer { controller.stop(); panel.close(); main.close() }
      TestWorkspaceFocus.link(main: main, quick: panel)
      controller.attach(to: main)
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      HostedWorkspace.settle(1.0)
      #expect(tabs.accessory == nil)

      // The chip's own button path: a press on the selected chip, where
      // the accessory would open, goes to the main window instead.
      let strip = try #require(catcher(in: panel.contentView!))
      let chip = try #require(frames(strip)[live.id])
      click(at: windowPoint(chip.midX, chip.midY, in: strip), in: panel)
      guard await Self.waitFor({
        !panel.isVisible && main.isVisible && tabs.accessory?.tab == live.id
      }, timeout: 10) else {
        let state = "panelVisible=\(panel.isVisible); accessory=\(String(describing: tabs.accessory))"
        Issue.record("the accessory did not open on the main window: \(state)")
        return
      }
      #expect(tabs.accessory?.plugin == "test.plugin")
      // Summoned again over the open accessory, the panel's click is a
      // handoff, not a toggle: what the main window hosts stays open.
      controller.toggle()
      guard await Self.waitFor({ panel.isVisible }, timeout: 10) else {
        Issue.record("the panel never came back")
        return
      }
      HostedWorkspace.settle(0.5)
      click(at: windowPoint(chip.midX, chip.midY, in: strip), in: panel)
      guard await Self.waitFor({ !panel.isVisible && main.isVisible }, timeout: 10) else {
        Issue.record("the second click did not hand off to the main window")
        return
      }
      #expect(tabs.accessory?.tab == live.id, "the panel's click never toggles the accessory closed")
    }

    @Test("Change Host is hit-testable above the backdrop and a real row click selects the host", arguments: [false, true])
    func changeHostPickerHitTesting(quick: Bool) async throws {
      try await exerciseHostPicker(quick: quick, nativeMain: false)
    }

    @Test("Main picker and outside dismissal require an interactive macOS session",
      .enabled(if: ProcessInfo.processInfo.environment["TETHER_NATIVE_WINDOW_TESTS"] == "1"))
    func nativeMainPickerOutsideDismissal() async throws {
      try await exerciseHostPicker(quick: false, nativeMain: true)
    }

    private func exerciseHostPicker(quick: Bool, nativeMain usesNativeMain: Bool) async throws {
      let hosted = try HostedWorkspace(terminals: 0)
      let tabs = hosted.tabs
      let interaction = hosted.interaction
      let targetHost = Host(label: "Picker target", hostname: "target.invalid", port: 22, username: "preview")
      let otherHost = Host(label: "Picker other", hostname: "other.invalid", port: 22, username: "preview")
      try #require(interaction.store.save(targetHost) && interaction.store.save(otherHost))
      let target = SessionTab(preview: targetHost, known: KnownHosts(), name: "Target", live: true)
      let other = SessionTab(preview: otherHost, known: KnownHosts(), name: "Other", live: true)
      tabs.adopt(target)
      tabs.adopt(other)
      let controller = tabs.quickTerminal
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(
        tabs: tabs, registry: interaction.registry, controller: controller, interaction: interaction))
      // The native outside-tap case needs a real key window for SwiftUI's bare
      // outside-tap gesture. A synthetic isKeyWindow answer is insufficient.
      // Keep the existing quick fixture and its exclusive-focus seam unchanged.
      var nativeMain: WorkspaceWindow?
      if usesNativeMain {
        hosted.window.orderOut(nil)
        hosted.window.contentView = nil
        nativeMain = WorkspaceWindow(hosting: RootView(
          store: interaction.store, tabs: tabs, registry: interaction.registry, secrets: MemorySecrets(),
          plugins: PluginAPI(consent: DialogConsent()), installedPlugins: .constant(nil), interaction: interaction)
          .environment(\.workspaceIsPrimary, false), autosaveName: nil)
      } else {
        TestWorkspaceFocus.link(main: hosted.window, quick: panel)
      }
      defer { controller.stop(); panel.close(); nativeMain?.close(); hosted.tearDown() }
      let main: NSWindow = nativeMain ?? hosted.window
      controller.attach(to: main)
      controller.attach(panel: panel)
      let window: NSWindow = quick ? panel : main
      let hostID = quick ? controller.panelID : interaction.workspaceHostID
      window.setFrame(Self.frameInVisibleDisplay(width: 850, height: 620), display: false)
      if quick {
        window.orderFrontRegardless()
        window.makeKey()
        interaction.register(id: hostID, kind: .quick, window: panel)
      } else if usesNativeMain {
        interaction.register(id: hostID, kind: .workspace, window: window)
        try #require(interaction.performOnWorkspace({}))
        try #require(await waitFor({ NSApp.isActive && NSApp.keyWindow === window }, timeout: 5),
          "native input prerequisite unavailable: active=\(NSApp.isActive) nativeKey=\(NSApp.keyWindow === window)")
      } else {
        window.orderFrontRegardless()
        window.makeKey()
      }
      try #require(await waitFor({ interaction.effectiveHost == hostID }, timeout: 5))
      try #require(interaction.dispatch(.changeHost, from: hostID))
      let content = try #require(window.contentView)
      try #require(await waitFor({ Self.editableFields(in: content).contains {
        $0.placeholderString == "Find a host…"
      } }, timeout: 5))
      let search = try #require(Self.editableFields(in: content).first { $0.placeholderString == "Find a host…" })
      // NSView.hitTest expects its superview's coordinates, not its own.
      let searchPoint = search.convert(NSPoint(x: search.bounds.midX, y: search.bounds.midY), to: content.superview)
      let searchHit = try #require(content.hitTest(searchPoint))
      #expect(searchHit === search || searchHit.isDescendant(of: search) || searchHit === search.currentEditor(),
        "the picker or its shared field editor must receive the hit, not \(type(of: searchHit))")
      if usesNativeMain { try #require(NSApp.isActive && NSApp.keyWindow === window) }
      click(search)
      let editor = try #require(search.currentEditor() as? NSTextView)
      editor.selectAll(nil)
      editor.insertText("Picker target", replacementRange: editor.selectedRange())
      HostedWorkspace.settle(0.25)
      // Filtering leaves exactly one host row below the search. Click its
      // actual window coordinates, never invoke the button's action directly.
      let fieldFrame = search.convert(search.bounds, to: nil)
      let rowPoint = NSPoint(x: fieldFrame.midX,
        y: fieldFrame.minY - UIStyle.Space.inline - UIStyle.Space.group - UIStyle.rowHeight / 2)
      #expect(content.hitTest(content.superview?.convert(rowPoint, from: nil) ?? rowPoint) != nil)
      click(at: rowPoint, in: window)
      try #require(await waitFor({ !tabs.hostPicker && tabs.selected == target.id }, timeout: 5),
        "the foreground picker row must receive the click and reveal the existing preview host")
      #expect(tabs.currentHost?.id == targetHost.id && tabs.tabs.count == 2)
      #expect(window.isVisible && interaction.effectiveHost == hostID)

      // The ordinary main fixture proves real picker hit-testing and row
      // selection, not native activation. Its full outside-tap E2E remains
      // explicitly opt-in above; the quick fixture covers dismissal normally.
      guard quick || usesNativeMain else { return }
      try #require(await waitFor({ !Self.editableFields(in: content).contains {
        $0.placeholderString == "Find a host…"
      } }, timeout: 5), "the answered picker must actually leave before it is reopened")
      try #require(interaction.dispatch(.changeHost, from: hostID))
      try #require(await waitFor({ Self.editableFields(in: content).contains {
        $0.placeholderString == "Find a host…" && $0.currentEditor() != nil
      } }, timeout: 5))
      let outside = content.convert(NSPoint(x: content.bounds.maxX - 20, y: content.bounds.midY), to: nil)
      let outsideHit = content.hitTest(content.superview?.convert(outside, from: nil) ?? outside)
      let outsideReport = "quick=\(quick) point=\(outside) contentFrame=\(content.frame) " +
        "hit=\(outsideHit.map { String(describing: type(of: $0)) } ?? "nil") " +
        "key=\(window.isKeyWindow) editor=\(String(describing: window.firstResponder.map { type(of: $0) }))"
      if usesNativeMain {
        try #require(NSApp.isActive && NSApp.keyWindow === window,
          "native input prerequisite lost before outside click: \(outsideReport)")
      }
      click(at: outside, in: window)
      try #require(await waitFor({ !tabs.hostPicker }, timeout: 5),
        "a click outside the picker still dismisses it: \(outsideReport)")
    }

    @Test("Quick single and split terminals stop claiming input during palette, rename and a question, then recover",
      .enabled(if: TerminalSession.isLocalAvailable), arguments: [false, true])
    func terminalInputGate(split: Bool) async throws {
      let hosted = try HostedWorkspace(terminals: 0)
      let tabs = hosted.tabs
      let interaction = hosted.interaction
      let first = SessionTab(host: .local, password: "", known: KnownHosts(), name: "Input first")
      tabs.adopt(first)
      first.setPublishesFrames(true)
      let workspace = try #require(tabs.currentWorkspace?.id)
      if split {
        let second = SessionTab(host: .local, password: "", known: KnownHosts(), name: "Input second")
        tabs.adopt(second, in: workspace)
        second.setPublishesFrames(true)
        try #require(tabs.place(second.id, beside: first.id, edge: .right))
      }
      let controller = tabs.quickTerminal
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(
        tabs: tabs, registry: interaction.registry, controller: controller, interaction: interaction))
      defer { controller.stop(); panel.close(); hosted.tearDown() }
      TestWorkspaceFocus.link(main: hosted.window, quick: panel)
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(Self.frameInVisibleDisplay(width: 850, height: 500), display: false)
      panel.orderFrontRegardless()
      panel.makeKey()
      interaction.register(id: controller.panelID, kind: .quick, window: panel)
      let content = try #require(panel.contentView)
      let expectedCount = split ? 2 : 1
      try #require(await waitFor({
        Self.keyCaptures(in: content).count == expectedCount
          && Self.keyCaptures(in: content).filter(\.wantsFocus).count == 1
      }, timeout: 15), "real terminal frames must create one active selected-pane capture")
      let selected = try #require(tabs.selected)
      for blocker in 0..<3 {
        switch blocker {
        case 0: try #require(interaction.dispatch(.commandMenu, from: controller.panelID))
        case 1: tabs.beginRenamingTerminal(selected)
        default: tabs.pendingClose = selected
        }
        try #require(await waitFor({ Self.keyCaptures(in: content).allSatisfy { !$0.wantsFocus } }, timeout: 5))
        let captures = Self.keyCaptures(in: content)
        #expect(captures.count == expectedCount)
        #expect(!captures.contains { panel.firstResponder === $0 })
        // Another SwiftUI update must not let the terminal reclaim a field's
        // input while the same blocker is still up.
        first.pinnedName = "Input refresh \(blocker)"
        await Task.yield()
        #expect(Self.keyCaptures(in: content).allSatisfy { !$0.wantsFocus })
        switch blocker {
        case 0: tabs.palette = nil
        case 1: tabs.renaming = nil
        default: tabs.cancelClose()
        }
        try #require(await waitFor({
          Self.keyCaptures(in: content).filter(\.wantsFocus).count == 1
            && Self.keyCaptures(in: content).contains { $0.wantsFocus && panel.firstResponder === $0 }
        }, timeout: 5), "the selected terminal recovers input after the blocker closes")
      }
    }

    private static func keyCaptures(in view: NSView) -> [KeyCaptureView] {
      let own = (view as? KeyCaptureView).map { [$0] } ?? []
      return own + view.subviews.flatMap { keyCaptures(in: $0) }
    }

    @Test("the strip's menu performs workspace actions through the handoff route, and through the TabSet by default")
    func stripMenuRoutesActions() throws {
      let suite = "quick-root-strip-menu.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)

      // A strip that hands actions off — the quick panel's — never lets
      // its menu perform on the shared TabSet: the action leaves through
      // the handoff route instead, and no intent is stranded here.
      var handed: WorkspaceAction?
      let quickBar = WorkspaceTabBar(tabs: tabs, performAction: { handed = $0 }, onClose: { _ in })
      let menu = quickBar.tabMenu(try #require(tabs.selected))
      let newTerminal = try #require(menu.items.first { $0.title == "New Terminal" })
      NSApp.sendAction(newTerminal.action!, to: newTerminal.target, from: newTerminal)
      #expect(handed == .newTerminal, "the menu action leaves through the handoff route")
      #expect(tabs.intent == nil, "nothing is performed on the shared TabSet here")

      // The workspace window's strip, with no handoff, performs as it
      // always has.
      let mainBar = WorkspaceTabBar(tabs: tabs, onClose: { _ in })
      let mainMenu = mainBar.tabMenu(try #require(tabs.selected))
      let mainItem = try #require(mainMenu.items.first { $0.title == "New Terminal" })
      NSApp.sendAction(mainItem.action!, to: mainItem.target, from: mainItem)
      #expect(tabs.intent != nil, "the default strip still performs on the shared TabSet")
    }

    @Test("toggle tab bar with the panel focused answers for the panel alone",
      .enabled(if: TerminalSession.isLocalAvailable))
    func toggleTabBarScopedToFocusedPanel() async throws {
      let suite = "quick-root-toggle-panel.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let pair = try await FramedPair(defaults: defaults)
      defer { pair.close() }
      try await pair.summonPanel()
      let tabs = pair.tabs
      let panel = try #require(pair.panel)
      let content = try #require(panel.contentView)
      let mainID = pair.mainID
      // No default chord for the tab bar; a person's own binding takes
      // the same path the settings store gives it.
      let chord = KeyBinding("b", [.control, .option, .command])
      try tabs.keyBindings.set(chord, for: WorkspaceAction.toggleTabBar.command, slot: 0,
        commands: WorkspaceAction.allCases.map(\.command))

      // The panel holds the key: the toggle hides the panel's bar. The
      // panel stays up and in front — nothing hands off, nothing is
      // revealed — and the workspace window keeps its own bar.
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      guard await Self.waitFor({
        self.catchers(in: content).isEmpty && panel.isVisible
          && pair.interaction.effectiveHost == pair.controller.panelID
      }, timeout: 10) else {
        Issue.record("the panel's bar did not hide, or the panel gave up the front")
        return
      }
      #expect(tabs.showsTabBar(for: mainID), "the workspace window's bar is untouched")
      // The grid follows the viewport the bar leaves behind.
      guard await Self.waitFor({
        guard let gpu = Self.gpuView(in: content) else { return false }
        return gpu.convert(gpu.bounds, to: nil).height == content.bounds.height
      }, timeout: 10) else {
        Issue.record("the terminal did not refit without the bar")
        return
      }

      // Once more: the bar comes back and the terminal refits below it —
      // still the panel's alone.
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      guard await Self.waitFor({
        !self.catchers(in: content).isEmpty && panel.isVisible
          && pair.interaction.effectiveHost == pair.controller.panelID
      }, timeout: 10) else {
        Issue.record("the panel's bar did not come back")
        return
      }
      #expect(tabs.showsTabBar(for: mainID))
      guard await Self.waitFor({
        guard let gpu = Self.gpuView(in: content) else { return false }
        return gpu.convert(gpu.bounds, to: nil).height == content.bounds.height - Chrome.tab
      }, timeout: 10) else {
        Issue.record("the terminal did not refit below the bar")
        return
      }
    }

    @Test("the first toggle chord after switching quick to main works in the same runloop with local or global-plus-local routing",
      arguments: [false, true])
    func toggleTabBarScopedToFocusedMain(globalAndLocal: Bool) async throws {
      let hosted = try HostedWorkspace(terminals: 1, installGlobalShortcuts: globalAndLocal)
      let tabs = hosted.tabs
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer {
        tabs.closeAll()
        controller.stop()
        panel.close()
        hosted.tearDown()
      }
      TestWorkspaceFocus.link(main: hosted.window, quick: panel)
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      // The reports the native bridge would deliver; the fixtures say
      // them out loud where a test double keeps the bridge from running.
      interaction.register(id: controller.panelID, kind: .quick, window: panel)
      HostedWorkspace.settle(1.0)
      let panelContent = try #require(panel.contentView)
      let mainContent = try #require(hosted.window.contentView)
      let chord = KeyBinding("b", [.control, .option, .command])
      try tabs.keyBindings.set(chord, for: WorkspaceAction.toggleTabBar.command, slot: 0,
        commands: WorkspaceAction.allCases.map(\.command))

      // Panel first: only the panel's bar goes.
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      #expect(!tabs.showsTabBar(for: controller.panelID), "one event toggles the model once before view updates")
      guard await Self.waitFor({
        self.catchers(in: panelContent).isEmpty && !self.catchers(in: mainContent).isEmpty
      }, timeout: 10) else {
        Issue.record("the panel's bar did not hide alone")
        return
      }

      // The workspace window in front: only its bar goes; the panel's
      // hiding is its own and stays. Its id is what its root noted; the
      // hook reports the key even while occlusion withholds shown.
      panel.orderOut(nil)
      hosted.window.makeKey()
      // The workspace window's own root registered this id (the stable
      // workspaceHostID); the fixture speaks its native report.
      let mainID = hosted.interaction.workspaceHostID
      #expect(hosted.window.isKeyWindow && !panel.isKeyWindow)
      #expect(hosted.interaction === interaction && tabs.interaction === interaction)
      #expect(interaction.hostID(for: hosted.window) == mainID)
      #expect(interaction.hostID(for: panel) == controller.panelID)
      #expect(hosted.window.isKeyWindow && hosted.window.attachedSheet == nil && NSApp.modalWindow == nil)
      #expect(interaction.effectiveHost == mainID && interaction.shortcutsAllowed(in: mainID))
      #expect(tabs.canPerform(.toggleTabBar) && tabs.showsTabBar(for: mainID))
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: hosted.window)
      #expect(!tabs.showsTabBar(for: mainID), "the first main key is not blocked by the previous SwiftUI snapshot")
      guard await Self.waitFor({
        self.catchers(in: mainContent).isEmpty && !tabs.showsTabBar(for: mainID)
      }, timeout: 10) else {
        Issue.record("the workspace window's bar did not hide alone")
        return
      }
      #expect(!tabs.showsTabBar(for: controller.panelID), "the panel's hiding is its own and stays")

      // Back to the panel: its toggle answers for it alone again — the
      // workspace window's bar stays hidden.
      controller.toggle()
      panel.makeKey()
      #expect(panel.isKeyWindow && !hosted.window.isKeyWindow)
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      #expect(tabs.showsTabBar(for: controller.panelID), "one event cannot be executed by both monitors")
      guard await Self.waitFor({
        !self.catchers(in: panelContent).isEmpty && self.catchers(in: mainContent).isEmpty
      }, timeout: 10) else {
        Issue.record("the panel's bar did not return alone")
        return
      }
    }

    @Test("with the preference off, the panel's toggle shows its own bar and hides it again; the workspace window stays hidden")
    func toggleTabBarFromHiddenPreference() async throws {
      let suite = "quick-root-toggle-hidden-pref.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(false, forKey: TabBarPreference.key)
      let tabs = TabSet(defaults: defaults)
      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)
      // A workspace window on these tabs: it reports itself and never
      // chooses an override, so the preference decides for it.
      let mainID = UUID()
      let interaction = try Self.makeInteraction(tabs: tabs)
      interaction.register(id: mainID, kind: .workspace)
      interaction.update(id: mainID, state: WorkspaceHostState(
        orderedIn: true, renderVisible: true, keyWithinHost: false))
      let controller = tabs.quickTerminal
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer { controller.stop(); panel.close() }
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      interaction.register(id: controller.panelID, kind: .quick, window: panel)
      interaction.update(id: controller.panelID, state: WorkspaceHostState(
        orderedIn: true, renderVisible: true, keyWithinHost: true))
      HostedWorkspace.settle(1.0)
      let content = try #require(panel.contentView)
      let chord = KeyBinding("b", [.control, .option, .command])
      try tabs.keyBindings.set(chord, for: WorkspaceAction.toggleTabBar.command, slot: 0,
        commands: WorkspaceAction.allCases.map(\.command))

      // The preference is off: no window shows the bar.
      #expect(self.catchers(in: content).isEmpty)
      #expect(!tabs.showsTabBar(for: mainID))

      // The panel's toggle answers for the panel: its bar shows, the
      // workspace window's stays hidden.
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      guard await Self.waitFor({
        !self.catchers(in: content).isEmpty && panel.isVisible
      }, timeout: 10) else {
        Issue.record("the panel's bar did not show")
        return
      }
      #expect(tabs.showsTabBar(for: controller.panelID))
      #expect(!tabs.showsTabBar(for: mainID), "the workspace window stays hidden")

      // Again: the panel's bar hides, and the workspace window still
      // never chose an override — the preference decides for it.
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      guard await Self.waitFor({
        self.catchers(in: content).isEmpty && panel.isVisible
      }, timeout: 10) else {
        Issue.record("the panel's bar did not hide again")
        return
      }
      #expect(!tabs.showsTabBar(for: mainID))
    }

    @Test("the panel's tab bar follows the tab layout preference — top strip or leading sidebar — switching live",
      .enabled(if: TerminalSession.isLocalAvailable))
    func tabLayoutFollowsPreference() async throws {
      let suite = "quick-root-tab-layout.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let pair = try await FramedPair(defaults: defaults)
      defer { pair.close() }
      try await pair.summonPanel()
      let tabs = pair.tabs
      let panel = try #require(pair.panel)
      let content = try #require(panel.contentView)
      let chord = KeyBinding("b", [.control, .option, .command])
      try tabs.keyBindings.set(chord, for: WorkspaceAction.toggleTabBar.command, slot: 0,
        commands: WorkspaceAction.allCases.map(\.command))

      // The preference and the sidebar width are the shared ones; speak
      // them here and put them back, the way the settings store would.
      let standard = UserDefaults.standard
      let previousLayout = standard.object(forKey: TabLayout.preferenceKey) as? String
      let previousWidth = standard.object(forKey: "workspace.tabSidebarWidth") as? Double
      defer {
        if let previousLayout { standard.set(previousLayout, forKey: TabLayout.preferenceKey) }
        else { standard.removeObject(forKey: TabLayout.preferenceKey) }
        if let previousWidth { standard.set(previousWidth, forKey: "workspace.tabSidebarWidth") }
        else { standard.removeObject(forKey: "workspace.tabSidebarWidth") }
      }
      standard.set(TabLayout.vertical.rawValue, forKey: TabLayout.preferenceKey)
      standard.set(Double(Chrome.tabSidebarIdeal), forKey: "workspace.tabSidebarWidth")

      // Vertical: the strip is a full-height leading sidebar at the
      // preference's width, and the terminal fills the rest — every
      // point of height, the width the sidebar leaves.
      guard await Self.waitFor({
        guard let strip = self.catchers(in: content).first,
          let gpu = Self.gpuView(in: content) else { return false }
        let stripFrame = strip.convert(strip.bounds, to: nil)
        let gpuFrame = gpu.convert(gpu.bounds, to: nil)
        return self.catchers(in: content).count == 1
          && stripFrame.minX == 0 && stripFrame.height == content.bounds.height
          && abs(stripFrame.width - Chrome.tabSidebarIdeal) < 0.5
          && abs(gpuFrame.minX - stripFrame.maxX) <= 1.5
          && abs(gpuFrame.width - (content.bounds.width - gpuFrame.minX)) < 0.5
          && gpuFrame.height == content.bounds.height
      }, timeout: 10) else {
        let report = Self.describeGeometry(in: content)
        Issue.record("the vertical layout did not take: \(report)")
        return
      }

      // Hiding and showing the bar keeps following the layout: the
      // terminal takes the whole window, then the sidebar comes back.
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      guard await Self.waitFor({
        guard let gpu = Self.gpuView(in: content) else { return false }
        let gpuFrame = gpu.convert(gpu.bounds, to: nil)
        return self.catchers(in: content).isEmpty
          && gpuFrame.minX == 0 && gpuFrame.width == content.bounds.width
      }, timeout: 10) else {
        Issue.record("hiding the vertical bar did not give the terminal the whole window")
        return
      }
      press("b", keyCode: 11, modifiers: [.control, .option, .command], in: panel)
      guard await Self.waitFor({
        guard let strip = self.catchers(in: content).first,
          let gpu = Self.gpuView(in: content) else { return false }
        let stripFrame = strip.convert(strip.bounds, to: nil)
        let gpuFrame = gpu.convert(gpu.bounds, to: nil)
        return stripFrame.height == content.bounds.height
          && abs(gpuFrame.minX - stripFrame.maxX) <= 1.5
      }, timeout: 10) else {
        Issue.record("showing the vertical bar did not bring the sidebar back")
        return
      }

      // Back to horizontal: the one chrome row is the top strip again,
      // the terminal below it.
      standard.set(TabLayout.horizontal.rawValue, forKey: TabLayout.preferenceKey)
      guard await Self.waitFor({
        guard let strip = self.catchers(in: content).first,
          let gpu = Self.gpuView(in: content) else { return false }
        let stripFrame = strip.convert(strip.bounds, to: nil)
        let gpuFrame = gpu.convert(gpu.bounds, to: nil)
        return stripFrame.maxY == content.bounds.height && stripFrame.height == Chrome.tab
          && gpuFrame.maxY == content.bounds.height - Chrome.tab
          && gpuFrame.height == content.bounds.height - Chrome.tab
      }, timeout: 10) else {
        Issue.record("switching back to horizontal did not restore the top strip")
        return
      }
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
      let interaction = try Self.makeInteraction(tabs: tabs)
      let main = KeyedWindow.make()
      interaction.register(id: interaction.workspaceHostID, kind: .workspace, window: main)
      let panel = KeyedQuickPanel(hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer { controller.stop(); panel.close(); main.close() }
      TestWorkspaceFocus.link(main: main, quick: panel)
      controller.attach(to: main)
      controller.attach(panel: panel)

      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      HostedWorkspace.settle(1.0)
      #expect(QuickPresentation.presentation(for: tabs) == .pluginWorkspace)

      // SwiftUI draws the button as a focus-ring view inside its graphics
      // view, not an AppKit button. The strip has buttons of its own
      // now: the offer is the one below the strip, where the content
      // area centers it. Click where it draws, the way a person's click
      // arrives: through the window.
      let contentHeight = panel.contentView!.bounds.height
      let offers = findViews("_FocusRingView", in: panel.contentView!).filter {
        $0.convert($0.bounds, to: nil).maxY < contentHeight - Chrome.tab
      }
      let offer = offers.first
      #expect(offer != nil, "the panel offers the main window rather than plugin content")
      guard let offer else { return }

      click(offer)
      try await Task.sleep(for: .milliseconds(500))
      #expect(!panel.isVisible, "the offer steps the panel aside")
      #expect(main.isVisible, "and brings the main window forward")
      #expect(!controller.isQuick)
    }

    @Test("a questioning or down tab is still the panel's terminal; its question is the controller's ordinary dialog, not a panel offer")
    func problemTabStaysTerminal() throws {
      let suite = "quick-root-offer.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      let live = SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true)
      tabs.adopt(live)
      #expect(QuickPresentation.presentation(for: tabs) == .terminal(live.id))

      // A question does not turn the panel's terminal into an offer page:
      // the tab is still what the panel draws. The question itself is an
      // ordinary dialog, submitted once by the controller where the
      // person is — never a second presenter in the panel.
      live.fail(TetherError.authenticationFailed(remaining: []))
      #expect(QuickPresentation.presentation(for: tabs) == .terminal(live.id))

      live.setProblemAside()
      #expect(QuickPresentation.presentation(for: tabs) == .terminal(live.id))

      // One preserved question: raising it again changes nothing, and the
      // quick never recreates or cancels the shared dialog request.
      live.raiseProblem()
      live.raiseProblem()
      #expect(live.problemRaised)
      #expect(QuickPresentation.presentation(for: tabs) == .terminal(live.id))
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
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
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

    @Test("the new-tab chord in the panel opens exactly once with local or global-plus-local routing",
      arguments: [false, true])
    func newTabChordOpensInPanel(globalAndLocal: Bool) async throws {
      // The real hosted workspace consumes actions the way the app does.
      let hosted = try HostedWorkspace(terminals: 1, installGlobalShortcuts: globalAndLocal)
      let tabs = hosted.tabs
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer {
        tabs.closeAll()
        controller.stop()
        panel.close()
        hosted.tearDown()
      }
      TestWorkspaceFocus.link(main: hosted.window, quick: panel)
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 400), display: false)
      panel.orderFront(nil)
      panel.makeKey()
      interaction.register(id: controller.panelID, kind: .quick, window: panel)
      HostedWorkspace.settle(1.0)

      let count = tabs.tabs.count
      #expect(hosted.interaction === interaction && tabs.interaction === interaction)
      #expect(interaction.hostID(for: panel) == controller.panelID)
      #expect(panel.isKeyWindow && panel.attachedSheet == nil && NSApp.modalWindow == nil)
      #expect(interaction.shortcutsAllowed(in: controller.panelID) && tabs.canPerform(.newTab))
      press("t", keyCode: 17, modifiers: [.command], in: panel)
      #expect(tabs.tabs.count == count + 1, "the real key executes the domain action synchronously once")
      // Consumed, not stranded: exactly one tab came of it, the panel is
      // still up and still the effective host — a second perform would
      // show a second new tab, a handoff would hide the panel.
      guard await waitFor({
        tabs.tabs.count == count + 1 && panel.isVisible
          && interaction.effectiveHost == controller.panelID
      }, timeout: 15) else {
        Issue.record("the new tab did not open in the panel")
        return
      }
    }

    @Test("a native question fixed to the main host blocks panel commands without transferring or duplicating it")
    func sharedBlockerGatesQuick() async throws {
      let hosted = try HostedWorkspace(terminals: 1)
      let tabs = hosted.tabs
      let chord = KeyBinding("p", [.control, .option, .command])
      try tabs.keyBindings.set(chord, for: WorkspaceAction.nextTab.command, slot: 0,
        commands: WorkspaceAction.allCases.map(\.command))
      let controller = tabs.quickTerminal
      let interaction = try Self.makeInteraction(tabs: tabs)
      let panel = KeyedQuickPanel(
        hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
      defer { controller.stop(); panel.close(); hosted.tearDown() }
      TestWorkspaceFocus.link(main: hosted.window, quick: panel)
      controller.attach(to: hosted.window)
      controller.attach(panel: panel)
      panel.setFrame(Self.frameInVisibleDisplay(width: 800, height: 400), display: false)
      panel.orderFrontRegardless()
      panel.makeKey()
      HostedWorkspace.settle(1.0)
      let selected = try #require(tabs.selected)

      // Fix the owner before asking, as an action sourced in main would.
      // This is the same stable controller the two roots were given.
      hosted.window.makeKey()
      #expect(hosted.window.isKeyWindow && !panel.isKeyWindow)
      #expect(interaction.effectiveHost == interaction.workspaceHostID)
      interaction.start()
      tabs.pendingClose = selected
      guard await waitFor({ self.captureOwnedDialog(on: hosted.window) != nil }, timeout: 10) else {
        Issue.record("the owned dialog never appeared. \(self.dialogDiagnostics(host: hosted.window))")
        await dismissOwnedDialog(tabs: tabs, host: hosted.window)
        return
      }
      do {
        #expect(interaction.presentationOwner == interaction.workspaceHostID)
        #expect(!interaction.shortcutsAllowed(in: controller.panelID))
        #expect(!interaction.inputAllowed(in: controller.panelID))
        #expect(panel.attachedSheet == nil && panel.childWindows?.isEmpty != false)
        press("p", keyCode: 35, modifiers: [.control, .option, .command], in: panel)
        #expect(tabs.selected == selected, "selection must not move behind the main window's question")
        #expect(interaction.presentationOwner == interaction.workspaceHostID)
        #expect(QuickPresentation.presentation(for: tabs) == .terminal(selected),
          "an ordinary question does not replace the quick terminal with the old main-window offer")
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
      tabs.interaction?.stop()
      guard await waitFor({
        (dialog.map { self.dialogGone($0, host: host) } ?? (self.captureOwnedDialog(on: host) == nil))
          && tabs.interaction?.hasBlockingPresentation != true
      }, timeout: 10) else {
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
      let interaction: WorkspaceInteraction

      var body: some View {
        SessionView(tab: tab)
          .environment(\.isFrontWindow, interaction.drivesSurface(windowID))
          .environment(\.surfaceDrivesSize, interaction.drivesSurface(windowID))
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
      let interaction: WorkspaceInteraction
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
        controller.frontmostApplication = { nil }
        interaction = try QuickTerminalRootTests.makeInteraction(tabs: tabs)
        mainID = interaction.workspaceHostID
        main = KeyedWindow.make()
        TestWorkspaceFocus.link(main: main)
        main.setFrame(QuickTerminalRootTests.frameInVisibleDisplay(width: 900, height: 600), display: false)
        main.contentView = NSHostingView(rootView: HostedMainSurface(tabs: tabs, tab: tab, windowID: mainID, interaction: interaction))
        main.orderFrontRegardless()
        main.makeKey()
        interaction.register(id: mainID, kind: .workspace, window: main)
        #expect(main.isKeyWindow && interaction.effectiveHost == mainID)
        // A shell's first frame is its initial 80x24, not evidence that
        // this surface sized it. Await the actual native viewport's grid
        // being accepted by the session before capturing the baseline.
        guard await QuickTerminalRootTests.waitFor({
          guard self.interaction.effectiveHost == self.mainID,
            let content = self.main.contentView,
            let gpu = QuickTerminalRootTests.gpuView(in: content),
            let grid = self.surfaceGrid(gpu), let frame = tab.frame else { return false }
          return frame.columns == grid.columns && frame.rows == grid.rows
        }, timeout: 10) else {
          Issue.record("the main surface never sized the session. \(self.readinessReport(panel: nil))")
          close()
          throw CancellationError()
        }
        mainColumns = tab.frame?.columns
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
          hosting: QuickTerminalRoot(tabs: tabs, registry: PluginRegistry(), controller: controller, interaction: interaction))
        self.panel = panel
        TestWorkspaceFocus.link(main: main, quick: panel)
        controller.attach(to: main)
        controller.attach(panel: panel)
        panel.setFrame(QuickTerminalRootTests.frameInVisibleDisplay(width: 700, height: 320), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        interaction.register(id: controller.panelID, kind: .quick, window: panel)
        #expect(panel.isKeyWindow && !main.isKeyWindow)
        let appShown = await QuickTerminalRootTests.waitFor({ !NSApp.isHidden }, timeout: 5)
        let panelVisible = await QuickTerminalRootTests.waitFor({
          panel.isVisible && !panel.isMiniaturized
            && panel.occlusionState.contains(.visible)
        }, timeout: 15)
        let panelFront = await QuickTerminalRootTests.waitFor(
          { self.interaction.effectiveHost == self.controller.panelID }, timeout: 10)
        let panelSized = await QuickTerminalRootTests.waitFor({
          self.tab.frame?.columns != nil && self.tab.frame?.columns != self.mainColumns
        }, timeout: 10)
        let ready = appShown && panelVisible && panelFront && panelSized
        guard ready else {
          let flags = "appShown=\(appShown) panelVisible=\(panelVisible) panelFront=\(panelFront) panelSized=\(panelSized)"
          Issue.record("fixture: the panel never became ready. \(flags); \(self.readinessReport(panel: panel))")
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
        parts.append("main visible=\(main.isVisible) occlusion=\(main.occlusionState.rawValue) " +
          "frame=\(main.frame) mainKey=\(main.isKeyWindow) panelKey=\(panel?.isKeyWindow ?? false)")
        parts.append("app hidden=\(NSApp.isHidden) modal=\(NSApp.modalWindow != nil) " +
          "main sheet=\(main.attachedSheet != nil) panel sheet=\(panel?.attachedSheet != nil)")
        parts.append("effective=\(String(describing: interaction.effectiveHost)) panelID=\(controller.panelID) " +
          "mainID=\(mainID) baselineColumns=\(String(describing: mainColumns)) currentColumns=\(String(describing: tab.frame?.columns)) " +
          "rows=\(String(describing: tab.frame?.rows))")
        parts.append("mainGPU=\(main.contentView.map { gpuReport(in: $0) } ?? "none")")
        parts.append("panelGPU=\(panel?.contentView.map { gpuReport(in: $0) } ?? "none") assignedPanelGPU=\(panelGPU != nil)")
        return parts.joined(separator: "; ")
      }

      private func gpuReport(in view: NSView) -> String {
        guard let gpu = QuickTerminalRootTests.gpuView(in: view) else { return "none" }
        return "bounds=\(gpu.bounds) frames=\(gpu.submittedFrames) fit=\(String(describing: surfaceGrid(gpu)))"
      }

      /// Read only the shaper metrics and padding already supplied to the
      /// actual native renderer. Never describe its pending ScreenFrame.
      private func surfaceGrid(_ gpu: TerminalGPUView) -> (columns: UInt32, rows: UInt32)? {
        guard gpu.bounds.width > 1, gpu.bounds.height > 1,
          let optional = Mirror(reflecting: gpu).children.first(where: { $0.label == "pending" })?.value,
          let pending = Mirror(reflecting: optional).children.first?.value else { return nil }
        let fields = Mirror(reflecting: pending).children
        guard let metrics = fields.first(where: { $0.label == "metrics" })?.value as? FontMetrics,
          let padding = fields.first(where: { $0.label == "padding" })?.value as? CGFloat else { return nil }
        return (UInt32(metrics.columns(fitting: gpu.bounds.width - 2 * max(0, padding) / metrics.scale)),
          UInt32(metrics.rows(fitting: gpu.bounds.height)))
      }

      func focusMain() {
        main.makeKey()
        #expect(main.isKeyWindow && panel?.isKeyWindow != true)
        #expect(interaction.effectiveHost == mainID)
      }

      func focusPanel() {
        // Focusing main may auto-hide the panel; show its unchanged frame
        // before asking the native bridge to make it effective again.
        panel?.orderFrontRegardless()
        panel?.makeKey()
        #expect(panel?.isVisible == true)
        #expect(panel?.isKeyWindow == true && !main.isKeyWindow)
        #expect(interaction.effectiveHost == controller.panelID)
      }

      func close() {
        interaction.stop()
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

    /// Every renderer in a hierarchy — one per visible split pane.
    private static func gpuViews(in view: NSView) -> [TerminalGPUView] {
      var found = view is TerminalGPUView ? [view as! TerminalGPUView] : []
      for subview in view.subviews { found += Self.gpuViews(in: subview) }
      return found
    }

    /// Every editable field — a palette's or the host picker's search.
    private static func editableFields(in view: NSView) -> [NSTextField] {
      var found = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
      for subview in view.subviews { found += Self.editableFields(in: subview) }
      return found
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

      // By now the panel has reported itself shown and key, holds the
      // front, and has sized the session to its own grid — that is the
      // front-sizing half of the contract.
      guard tab.frame?.columns != nil, pair.interaction.effectiveHost == pair.controller.panelID else {
        Issue.record("the panel in front never sized the session")
        return
      }
      let quickColumns = try #require(tab.frame?.columns)
      // The main window takes the front back: it reapplies the size it
      // kept while the panel was in front.
      pair.focusMain()
      guard await waitFor({ tab.frame.map { $0.columns > quickColumns + 5 } ?? false }, timeout: 10) else {
        Issue.record("the main window in front never took its size back")
        return
      }
      let mainColumns = try #require(tab.frame?.columns)
      // And the panel, front again, takes its size back.
      pair.focusPanel()
      guard await waitFor({ tab.frame.map { $0.columns < mainColumns - 5 } ?? false }, timeout: 10) else {
        Issue.record("the panel in front never reapplied its own size")
        return
      }
    }

    /// The quick terminal used in another app, the workspace window away:
    /// hiding the panel and summoning it again must come back with the
    /// panel's own grid, not the workspace window's drawn into the middle.
    @Test("with the workspace window away, a re-summon keeps the panel's grid, not the workspace window's",
      .enabled(if: TerminalSession.isLocalAvailable))
    func resummonWhileWorkspaceAwayKeepsPanelGrid() async throws {
      let suite = "quick-root-resummon.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let pair = try await FramedPair(defaults: defaults)
      defer { pair.close() }
      try await pair.summonPanel()
      let tab = pair.tab
      let controller = pair.controller
      let panelID = controller.panelID

      // The workspace window goes away — hidden, or on another Space —
      // while the panel is still up: the front is the panel's alone.
      pair.main.orderOut(nil)

      // Hide the panel, then summon it again through the real controller
      // path, as the hotkey does from another app. The first summon
      // re-places the panel, and the frame change refits the grid.
      controller.toggle()
      try await Task.sleep(for: .milliseconds(600))
      controller.toggle()
      guard await Self.waitFor({ pair.interaction.effectiveHost == panelID && tab.frame != nil }, timeout: 15) else {
        Issue.record("the panel never regained the front")
        return
      }
      HostedWorkspace.settle(1.0)
      let panelColumns = try #require(tab.frame?.columns)
      let panelRows = try #require(tab.frame?.rows)

      // Once more, now at the frame the placement keeps: nothing refits
      // on this summon, so only the front arbitration can hold the grid.
      controller.toggle()
      try await Task.sleep(for: .milliseconds(600))
      controller.toggle()
      guard await Self.waitFor({ pair.interaction.effectiveHost == panelID }, timeout: 15) else {
        Issue.record("the panel never regained the front")
        return
      }
      HostedWorkspace.settle(1.0)
      #expect(tab.frame?.columns == panelColumns, "the panel's grid, not the workspace window's")
      #expect(tab.frame?.rows == panelRows)
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

    /// Debug: where the strip and terminal sit in the window.
    private static func describeGeometry(in view: NSView) -> String {
      let content = view.bounds
      var parts = ["content=\(content)"]
      for (index, strip) in catchersStatic(in: view).enumerated() {
        parts.append("strip\(index)=\(strip.convert(strip.bounds, to: nil))")
      }
      if let gpu = gpuView(in: view) {
        parts.append("gpu=\(gpu.convert(gpu.bounds, to: nil))")
      } else {
        parts.append("gpu=nil")
      }
      return parts.joined(separator: "; ")
    }

    private static func catchersStatic(in view: NSView) -> [NSView] {
      var found = String(describing: type(of: view)) == "Catcher" ? [view] : []
      for subview in view.subviews { found += catchersStatic(in: subview) }
      return found
    }

    /// One interaction per fixture, the way AppModel owns the real one.
    /// The store is the same in-memory shape `HostedWorkspace` builds.
    static func makeInteraction(tabs: TabSet, file: StaticString = #filePath, line: UInt = #line) throws
      -> WorkspaceInteraction {
      // HostedWorkspace already owns the executor its RootView uses. Never
      // replace the TabSet's weak forwarder with a second fixture controller.
      if let interaction = tabs.interaction { return interaction }
      let directory = FileManager.default.temporaryDirectory.appending(path: "interaction-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let store = HostStore(
        location: directory.appending(path: "config"), secrets: MemorySecrets(),
        credentials: DeviceCredentialStore(secrets: MemorySecrets()),
        databaseURL: directory.appending(path: "identity.sqlite"))
      let interaction = WorkspaceInteraction(
        tabs: tabs, store: store, registry: PluginRegistry(), secrets: MemorySecrets())
      tabs.quickTerminal.interaction = interaction
      return interaction
    }

    /// The first value the condition produces, nil on timeout.
    private static func waitForValue<T>(
      _ value: @MainActor () -> T?, timeout: TimeInterval
    ) async -> T? {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if let value = value() { return value }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return value()
    }

    private func findView(_ className: String, in view: NSView) -> NSView? {
      findViews(className, in: view).first
    }

    private func findViews(_ className: String, in view: NSView) -> [NSView] {
      var found = String(describing: type(of: view)) == className ? [view] : []
      for subview in view.subviews { found += findViews(className, in: subview) }
      return found
    }

    /// The tab strip's event catcher, the same view the tab-strip tests
    /// reach through.
    private func catcher(in view: NSView) -> NSView? {
      if String(describing: type(of: view)) == "Catcher" { return view }
      for subview in view.subviews {
        if let found = catcher(in: subview) { return found }
      }
      return nil
    }

    private func catchers(in view: NSView) -> [NSView] {
      var found = String(describing: type(of: view)) == "Catcher" ? [view] : []
      for subview in view.subviews { found += catchers(in: subview) }
      return found
    }

    /// The chip frames the catcher reads its presses from, in its own
    /// (top-left) coordinates.
    private func frames(_ catcher: NSView) -> [UUID: CGRect] {
      Mirror(reflecting: catcher).children.first { $0.label == "frames" }?.value as? [UUID: CGRect] ?? [:]
    }

    /// SwiftUI frames are top-left; the strip may be either way up.
    private func windowPoint(_ x: CGFloat, _ y: CGFloat, in strip: NSView) -> NSPoint {
      strip.convert(NSPoint(x: x, y: strip.isFlipped ? y : strip.bounds.height - y), to: nil)
    }

    /// Down and up at a window point, the way a person's click arrives.
    private func click(at point: NSPoint, in window: NSWindow) {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
      }
      HostedWorkspace.settle(0.25)
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
