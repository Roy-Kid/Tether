#if os(macOS)
import AppKit
import Testing
import TetherPluginKit
import TetherTestSupport
import TetherUI
@testable import TetherApp
import struct TetherApp.Host

@MainActor
private final class InteractionDialogFixture {
  final class Panel: QuickTerminalWindow {
    var onOrderOut: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func orderOut(_ sender: Any?) {
      onOrderOut?()
      super.orderOut(sender)
    }
  }
  let location = temporaryFile("hosts.json")
  let suite = "Tether.InteractionDialogTests.\(UUID())"
  let defaults: UserDefaults
  let tabs: TabSet
  let interaction: WorkspaceInteraction
  let panel: Panel
  let panelID: UUID
  let tab: SessionTab
  var presentations = 0
  var answers = 0
  private var observer: NSObjectProtocol?
  private weak var lastAnsweredSheet: NSWindow?
  private var orderOutEvents: [String] = []

  init(attachQuickPolicy: Bool = false) {
    defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "quickTerminal.enabled")
    defaults.set(false, forKey: "quickTerminal.menuBarIcon")
    let secrets = MemorySecrets()
    tabs = TabSet(defaults: defaults)
    panelID = tabs.quickTerminal.panelID
    interaction = WorkspaceInteraction(tabs: tabs,
      store: HostStore(location: location, secrets: secrets), registry: PluginRegistry(), secrets: secrets)
    tab = SessionTab(preview: Host(label: "Memory fixture", hostname: "unused.invalid", port: 22, username: "test"),
      known: tabs.known, name: "Retained preview", live: false)
    tabs.adopt(tab)
    panel = Panel(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 400),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.onOrderOut = { [weak self] in
      guard let self else { return }
      let event = "t=\(ProcessInfo.processInfo.systemUptime) " + self.diagnostics(first: self.lastAnsweredSheet) +
        " stack=" + Thread.callStackSymbols.prefix(18).joined(separator: " | ")
      if self.orderOutEvents.count < 12 { self.orderOutEvents.append(event) }
    }
    panel.orderFrontRegardless()
    panel.makeKey()
    // Queue tests exercise a native host, not quick's key-loss/auto-hide
    // policy on this off-screen panel. Only the handoff test needs that
    // controller attached; dedicated quick tests cover its hide policy.
    if attachQuickPolicy {
      tabs.quickTerminal.interaction = interaction
      tabs.quickTerminal.frontmostApplication = { nil }
      tabs.quickTerminal.attach(panel: panel)
    }
    interaction.register(id: panelID, kind: .quick, window: panel)
    _ = interaction.claim(panelID)
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.willBeginSheetNotification, object: panel, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.presentations += 1 } }
    interaction.start()
  }

  func showAgain() {
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: panel)
    _ = interaction.claim(panelID)
  }

  var sheet: NSWindow? { panel.attachedSheet ?? panel.childWindows?.first }

  func buttons(in view: NSView) -> [NSButton] {
    ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
  }

  func fields(in view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField, field.isEditable { return [field] }
    return view.subviews.flatMap { fields(in: $0) }
  }

  func press(_ title: String, on sheet: NSWindow) throws {
    lastAnsweredSheet = sheet
    let content = try #require(sheet.contentView)
    try #require(buttons(in: content).first { $0.title == title }).performClick(nil)
  }

  func diagnostics(first: NSWindow?) -> String {
    "oldVisible=\(first?.isVisible ?? false) oldSheetParent=\(first?.sheetParent != nil) " +
      "oldParent=\(first?.parent != nil) panelVisible=\(panel.isVisible) nativeKey=\(panel.isKeyWindow) " +
      "appActive=\(NSApp.isActive) nativeKeyNumber=\(NSApp.keyWindow?.windowNumber ?? -1) " +
      "effective=\(String(describing: interaction.effectiveHost)) leaseOwner=\(String(describing: interaction.presentationOwner)) " +
      "lease=\(interaction.hasBlockingPresentation) waiters=\(interaction.waitingForPresentationHostCount) " +
      "connect=\(interaction.connectRequests.count) problem=\(tabs.problem != nil) notice=\(interaction.notice != nil) " +
      "pendingClose=\(tabs.pendingClose != nil) presentations=\(presentations) orderOutCount=\(orderOutEvents.count)"
  }

  func waitForSecondSheet(after first: NSWindow) async -> Bool {
    let ready = await interactionDialogWait { self.presentations == 2 && self.sheet !== first && self.sheet?.isVisible == true }
    if !ready {
      print("QUEUE_SECOND_SHEET_FAILURE \(diagnostics(first: first))")
      for event in orderOutEvents { print("QUEUE_ORDER_OUT_HISTORY \(event)") }
    }
    return ready
  }

  func answerTask(for request: ConnectRequest, hideBeforeLease: Bool = false) -> Task<String, Error> {
    Task {
      let password = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
        interaction.reconnectAnswers[request.id] = continuation
        interaction.ask(request)
        if hideBeforeLease { panel.orderOut(nil) }
      }
      answers += 1
      return password
    }
  }

  func close() async {
    let owned = sheet
    interaction.stop()
    _ = await interactionDialogWait {
      !self.interaction.hasBlockingPresentation && self.interaction.waitingForPresentationHostCount == 0
        && self.panel.attachedSheet == nil && self.panel.childWindows?.isEmpty != false
        && (owned.map { !$0.isVisible && $0.sheetParent == nil && $0.parent == nil } ?? true)
    }
    #expect(!interaction.hasBlockingPresentation && panel.attachedSheet == nil)
    if let observer { NotificationCenter.default.removeObserver(observer) }
    tabs.quickTerminal.workspaceReveal = nil
    tabs.closeAll()
    tabs.quickTerminal.stop()
    panel.orderOut(nil)
    panel.close()
    defaults.removePersistentDomain(forName: suite)
    removeDirectory(of: location)
  }
}

@MainActor
private func interactionDialogWait(_ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(10)
  while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
  return condition()
}

@MainActor
@Suite("Workspace interaction native queue", .serialized, .appKitEventLoop)
struct WorkspaceInteractionDialogTests {
  @Test("changing the selected problem does not withdraw the displayed original tab's question")
  func displayedProblemRetainsSourceIdentity() async throws {
    let f = InteractionDialogFixture()
    do {
      f.tab.fail(NSError(domain: "Memory fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Original memory problem"]))
      try #require(await interactionDialogWait { f.sheet?.isVisible == true })
      let first = try #require(f.sheet)
      let other = SessionTab(preview: f.tab.host, known: f.tabs.known, name: "Other preview", live: false)
      f.tabs.adopt(other)
      other.fail(NSError(domain: "Memory fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Other memory problem"]))
      NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: f.panel)
      await Task.yield()
      #expect(f.tabs.problem?.tab == other.id, "the projection changed, not the original request's lifetime")
      #expect(f.sheet === first && first.isVisible && f.presentations == 1)
      try f.press("Close", on: first)
      try #require(await f.waitForSecondSheet(after: first), "\(f.diagnostics(first: first))")
      #expect(!f.tabs.tabs.contains { $0.id == f.tab.id })
      #expect(f.tabs.tabs.contains { $0.id == other.id })
      #expect(f.tabs.closedTabs.count == 1)
      other.setProblemAside()
      try #require(await interactionDialogWait { !f.interaction.hasBlockingPresentation && f.sheet == nil })
      #expect(f.tabs.tabs.first === other, "withdrawing the real source never runs its native Cancel action")
    } catch {
      await f.close()
      throw error
    }
    await f.close()
  }

  @Test("a started controller retains a retry question when its last host hides before lease acquisition")
  func hiddenBeforeLeaseRetainsRequest() async throws {
    let f = InteractionDialogFixture()
    let request = ConnectRequest(host: f.tab.host, retrying: f.tab.id)
    let answer = f.answerTask(for: request, hideBeforeLease: true)
    defer { answer.cancel() }
    do {
      try #require(await interactionDialogWait { f.interaction.waitingForPresentationHostCount == 1 })
      #expect(f.interaction.connectRequests.map(\.id) == [request.id])
      #expect(f.tabs.tabs.first === f.tab && f.tabs.closedTabs.isEmpty)
      #expect(f.answers == 0 && f.presentations == 0)
      f.showAgain()
      try #require(await interactionDialogWait { f.sheet?.isVisible == true })
      let sheet = try #require(f.sheet)
      try #require(f.fields(in: sheet.contentView!).first).stringValue = "memory-answer"
      try f.press("Connect", on: sheet)
      #expect(try await answer.value == "memory-answer")
      try #require(await interactionDialogWait { !f.interaction.hasBlockingPresentation && f.sheet == nil })
      #expect(f.answers == 1 && f.presentations == 1)
      #expect(f.interaction.connectRequests.isEmpty && f.interaction.reconnectAnswers.isEmpty)
      #expect(f.tabs.tabs.first === f.tab && f.tabs.closedTabs.isEmpty)
    } catch {
      await f.close()
      throw error
    }
    await f.close()
  }

  @Test("a new higher-priority problem cannot replace a displayed password field", arguments: [false, true])
  func displayedPasswordKeepsIdentity(closeQuestion: Bool) async throws {
    let f = InteractionDialogFixture()
    let request = ConnectRequest(host: f.tab.host, retrying: f.tab.id)
    let answer = f.answerTask(for: request)
    defer { answer.cancel() }
    do {
      try #require(await interactionDialogWait { f.sheet?.isVisible == true })
      let first = try #require(f.sheet)
      let field = try #require(f.fields(in: first.contentView!).first)
      #expect(field is NSSecureTextField)
      first.makeFirstResponder(field)
      let editor = try #require(field.currentEditor() as? NSTextView)
      editor.selectAll(nil)
      editor.insertText("preserved-draft", replacementRange: editor.selectedRange())
      if closeQuestion { f.tabs.pendingClose = f.tab.id }
      else { f.interaction.notice = WorkspaceNotice(title: "Queued notice", message: "Memory only") }
      NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: f.panel)
      await Task.yield()
      #expect(f.sheet === first && first.isVisible)
      #expect(field.stringValue == "preserved-draft")
      #expect(f.presentations == 1 && f.answers == 0)
      #expect(f.interaction.presentationOwner == f.panelID)
      try f.press("Connect", on: first)
      #expect(try await answer.value == "preserved-draft")
      try #require(await f.waitForSecondSheet(after: first), "\(f.diagnostics(first: first))")
      #expect(!first.isVisible && first.sheetParent == nil && first.parent == nil)
      #expect(f.answers == 1 && f.interaction.connectRequests.isEmpty)
      let second = try #require(f.sheet)
      try f.press(closeQuestion ? "Cancel" : "OK", on: second)
      try #require(await interactionDialogWait { !f.interaction.hasBlockingPresentation && f.sheet == nil })
      #expect(f.presentations == 2 && f.answers == 1)
      #expect(f.tabs.tabs.first === f.tab && f.tabs.closedTabs.isEmpty)
    } catch {
      await f.close()
      throw error
    }
    await f.close()
  }

  @Test("direct handshake-style asks wait while all hosts are hidden and stop cancels that wait once")
  func directAskWaitCancelledByStop() async throws {
    let f = InteractionDialogFixture()
    f.panel.orderOut(nil)
    let task = Task { await f.interaction.askDialog(Dialog.notice("Unseen memory question")) }
    do {
      try #require(await interactionDialogWait { f.interaction.waitingForPresentationHostCount == 1 })
      f.interaction.stop()
      f.interaction.stop()
      #expect(await task.value == nil)
      #expect(f.interaction.waitingForPresentationHostCount == 0 && f.presentations == 0)
      #expect(!f.interaction.hasBlockingPresentation)
    } catch {
      task.cancel()
      await f.close()
      throw error
    }
    await f.close()
  }

  @Test("an extra workspace's accessory handoff reveals its own native target once before changing its bar")
  func extraWorkspaceAccessoryTarget() async throws {
    let f = InteractionDialogFixture(attachQuickPolicy: true)
    let extraTabs = TabSet(defaults: f.defaults)
    extraTabs.quickTerminal = f.tabs.quickTerminal
    let extra = WorkspaceInteraction(tabs: extraTabs, store: f.interaction.store,
      registry: f.interaction.registry, secrets: MemorySecrets())
    let tab = SessionTab(preview: .local, known: extraTabs.known, name: "Extra preview", live: false)
    extraTabs.adopt(tab)
    let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    extra.register(id: extra.workspaceHostID, kind: .workspace, window: window)
    var targets: [NSWindow] = []
    extraTabs.quickTerminal.workspaceReveal = { target in
      targets.append(target)
      #expect(extraTabs.accessory == nil, "handoff precedes accessory/bar mutation")
      target.orderFrontRegardless()
      target.makeKey()
    }
    #expect(extra.showAccessory("fixture.plugin", on: tab.id))
    #expect(targets.count == 1 && targets.first === window)
    #expect(!f.panel.isVisible, "the main-only handoff retires quick without revealing a different workspace")
    #expect(extra.effectiveHost == extra.workspaceHostID)
    #expect(extraTabs.accessory == AccessoryRef(tab: tab.id, plugin: "fixture.plugin"))
    #expect(f.tabs.accessory == nil)
    extra.stop()
    extra.unregister(id: extra.workspaceHostID)
    extraTabs.closeAll()
    window.close()
    await f.close()
  }
}
#endif
