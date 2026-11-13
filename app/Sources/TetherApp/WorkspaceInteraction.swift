import Foundation
import Observation
import Tether
import TetherPluginKit
import TetherUI
#if os(macOS)
import AppKit
#endif

enum WorkspaceHostKind { case workspace, quick }

struct WorkspaceHostState: Equatable {
  var orderedIn = false
  var miniaturized = false
  var renderVisible = false
  var keyWithinHost = false
  var eligible: Bool { orderedIn && !miniaturized }
}

struct WorkspacePresentationLease: Hashable {
  let id: UUID
  let hostID: UUID
}

/// One executor for one set of sessions. Native hosts are weak and replaceable;
/// neither a SwiftUI view's lifetime nor NSWindow.main owns this context.
@MainActor @Observable
final class WorkspaceInteraction {
  let tabs: TabSet
  let store: HostStore
  let registry: PluginRegistry
  let secrets: any SecretStore
  let workspaceHostID: UUID
  let windowFeedback = WindowFeedback()
  private(set) var effectiveHost: UUID?
  private(set) var lastEffectiveHost: UUID?
  private(set) var started = false
  var connectRequests: [ConnectRequest] = []
  var reconnectAnswers: [UUID: CheckedContinuation<String, Error>] = [:]
  var notice: WorkspaceNotice?
  private var hosts: [UUID: HostRecord] = [:]
  private var claimOrder: [UUID] = []
  private var leases: [UUID: WorkspacePresentationLease] = [:]
  private var deferredClaim: UUID?
  private var dialogTask: Task<Void, Never>?
  private var dialogToken: UUID?
  private var dialogPending: (@MainActor () -> Bool)?
  private var observationGeneration = 0
  private var hostRevision = 0
  private(set) var lifecycleGeneration = 0
  private var stopped = false
  @ObservationIgnored private var ownedTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var hostWaiters: [UUID: HostWaiter] = [:]
  var ownedWorkCount: Int { ownedTasks.count }
  var waitingForPresentationHostCount: Int { hostWaiters.count }

  private struct HostWaiter {
    let generation: Int
    let afterRevision: Int?
    let continuation: CheckedContinuation<Void, Error>
  }

  @MainActor private final class HostRecord {
    let kind: WorkspaceHostKind
    var state = WorkspaceHostState()
    var anchor = DialogAnchor()
    #if os(macOS)
    weak var window: NSWindow?
    var bridge: NativeWorkspaceHostBridge?
    #endif
    init(kind: WorkspaceHostKind) { self.kind = kind }
  }

  init(tabs: TabSet, store: HostStore, registry: PluginRegistry,
       secrets: any SecretStore, workspaceHostID: UUID = UUID()) {
    self.tabs = tabs
    self.store = store
    self.registry = registry
    self.secrets = secrets
    self.workspaceHostID = workspaceHostID
    tabs.interaction = self
    for tab in tabs.tabs { tab.interaction = self }
  }

  func start() {
    guard !started else { return }
    started = true
    stopped = false
    if let intent = tabs.intent { tabs.intent = nil; submit(intent) }
    observeModel()
  }

  func stop() {
    windowFeedback.dismissAll()
    started = false
    stopped = true
    lifecycleGeneration += 1
    observationGeneration += 1
    dialogTask?.cancel()
    dialogTask = nil
    dialogToken = nil
    dialogPending = nil
    let tasks = Array(ownedTasks.values)
    tasks.forEach { $0.cancel() }
    let waiting = Array(hostWaiters.values)
    hostWaiters.removeAll()
    waiting.forEach { $0.continuation.resume(throwing: CancellationError()) }
    let answers = Array(reconnectAnswers.values)
    reconnectAnswers.removeAll()
    answers.forEach { $0.resume(throwing: CancellationError()) }
    connectRequests.removeAll()
  }

  func workIsCurrent(_ generation: Int) -> Bool {
    !stopped && lifecycleGeneration == generation && !Task.isCancelled
  }

  /// All fire-and-forget workspace work belongs to this lifetime. Capturing
  /// the generation before enqueueing also closes the stop-before-start race.
  func runOperation(_ operation: @escaping @MainActor (Int) async -> Void) {
    let generation = lifecycleGeneration
    guard workIsCurrent(generation) else { return }
    let id = UUID()
    ownedTasks[id] = Task { [weak self] in
      guard let self else { return }
      defer { self.ownedTasks.removeValue(forKey: id) }
      guard self.workIsCurrent(generation) else { return }
      await operation(generation)
    }
  }

  #if os(macOS)
  func register(id: UUID, kind: WorkspaceHostKind, window: NSWindow) {
    register(id: id, kind: kind)
    guard hosts[id]?.window !== window else { return }
    windowFeedback.dismiss(in: id)
    hosts[id]?.window = window
    hosts[id]?.anchor = DialogAnchor(window: window)
    hosts[id]?.bridge = NativeWorkspaceHostBridge(window: window, interaction: self, id: id)
    hostRevision += 1
    resumeHostWaiters()
  }

  func hostID(for window: NSWindow?) -> UUID? {
    guard let window else { return nil }
    if let id = hosts.first(where: { $0.value.window === window })?.key { return id }
    return hostID(for: window.sheetParent ?? window.parent)
  }
  #endif

  func register(id: UUID, kind: WorkspaceHostKind) {
    if hosts[id] == nil {
      hosts[id] = HostRecord(kind: kind)
      hostRevision += 1
      tabs.registerTabBarHost(id)
    }
  }

  func tabBarPersistence(for id: UUID) -> TabBarPersistence {
    if hosts[id]?.kind == .quick { return .quick }
    guard id == workspaceHostID, hosts[id]?.kind == .workspace else { return .windowLocal }
    #if os(macOS)
    // ExtraWindow already shares the primary quick controller. Its workspace
    // is a separate runtime instance, not another owner of the legacy key.
    if let owner = tabs.quickTerminal.interaction, owner !== self { return .windowLocal }
    #endif
    return .workspace
  }

  func unregister(id: UUID) {
    windowFeedback.dismiss(in: id)
    hosts.removeValue(forKey: id)
    hostRevision += 1
    claimOrder.removeAll { $0 == id }
    if deferredClaim == id { deferredClaim = nil }
    reconcileHost()
    resumeHostWaiters()
  }

  func update(id: UUID, state: WorkspaceHostState) {
    guard let host = hosts[id] else { return }
    var state = state
    #if os(macOS)
    // A view reporter knows its own window and perhaps one sheet. Native
    // ancestry is authoritative for deeper child focus; a render report must
    // not erase it just because the root itself is no longer key.
    if let window = host.window { state.keyWithinHost = NativeWorkspaceHostBridge.keyIsWithin(window) }
    #endif
    host.state = state
    if !state.eligible { windowFeedback.dismiss(in: id) }
    hostRevision += 1
    if state.keyWithinHost && state.eligible { _ = claim(id) }
    reconcileHost()
    resumeHostWaiters()
    refreshFrames()
    refreshMenuShortcuts()
    refreshDialogs()
  }

  @discardableResult
  func claim(_ id: UUID) -> Bool {
    guard hosts[id]?.state.eligible == true else { return false }
    if let owner = presentationOwner, owner != id {
      deferredClaim = id
      return false
    }
    claimOrder.removeAll { $0 == id }
    claimOrder.append(id)
    if effectiveHost != id { hostRevision += 1 }
    effectiveHost = id
    lastEffectiveHost = id
    refreshMenuShortcuts()
    resumeHostWaiters()
    return true
  }

  var presentationOwner: UUID? { leases.values.first?.hostID }
  var hasBlockingPresentation: Bool { !leases.isEmpty }

  /// A lease survives the action and its continuation; only native `gone`
  /// releases it. Multiple queued questions may share, never change, its host.
  func acquirePresentation(in id: UUID? = nil) -> WorkspacePresentationLease? {
    guard let owner = presentationOwner ?? id ?? effectiveHost,
      hosts[owner] != nil,
      presentationOwner == owner || hosts[owner]?.state.eligible == true else { return nil }
    let lease = WorkspacePresentationLease(id: UUID(), hostID: owner)
    leases[lease.id] = lease
    return lease
  }

  func presentationDidPresent(_ lease: WorkspacePresentationLease) {
    guard leases[lease.id] != nil else { return }
    effectiveHost = lease.hostID
    lastEffectiveHost = lease.hostID
    refreshMenuShortcuts()
  }

  func presentationDidDismiss(_ lease: WorkspacePresentationLease) {
    guard leases.removeValue(forKey: lease.id) != nil else { return }
    guard leases.isEmpty else { return }
    if let id = deferredClaim {
      deferredClaim = nil
      _ = claim(id)
    }
    reconcileHost()
    refreshMenuShortcuts()
    resumeHostWaiters()
    #if os(macOS)
    if tabs.quickTerminal.interaction === self { tabs.quickTerminal.presentationDidDismiss() }
    #endif
    refreshDialogs()
  }

  func windowAnchor(for id: UUID) -> DialogAnchor {
    precondition(hosts[id] != nil, "Register a workspace host before using its anchor")
    return hosts[id]!.anchor
  }

  private func reconcileHost() {
    if let owner = presentationOwner { effectiveHost = owner; return }
    if let current = effectiveHost, hosts[current]?.state.eligible == true { return }
    // Only previously claimed, still ordered hosts qualify. Never reveal one.
    effectiveHost = claimOrder.reversed().first { hosts[$0]?.state.eligible == true }
    if let effectiveHost { lastEffectiveHost = effectiveHost }
  }

  func drivesSurface(_ id: UUID) -> Bool {
    _ = hostRevision
    return effectiveHost == id && hosts[id]?.state.eligible == true
  }

  func inputAllowed(in id: UUID) -> Bool {
    drivesSurface(id) && !hasBlockingPresentation && tabs.palette == nil && !tabs.hostPicker
      && tabs.accessory == nil && tabs.sheet == nil && tabs.pendingClose == nil
      && tabs.renaming == nil && tabs.renamingWorkspace == nil && connectRequests.isEmpty && notice == nil
      && tabs.passwordOffer == nil && tabs.problem == nil
  }

  func shortcutsAllowed(in id: UUID) -> Bool {
    drivesSurface(id) && !hasBlockingPresentation && tabs.sheet == nil
      && tabs.pendingClose == nil && tabs.renaming == nil && tabs.renamingWorkspace == nil
      && connectRequests.isEmpty && notice == nil
  }

  private func sourceHost(_ from: UUID?) -> UUID? {
    if let from { return claim(from) ? from : nil }
    #if os(macOS)
    // Menus must not fall through to a remembered terminal while Settings
    // (or any unrelated native window) owns the keys.
    guard let id = hostID(for: NSApp?.keyWindow), hosts[id]?.state.eligible == true else { return nil }
    return claim(id) ? id : nil
    #else
    return effectiveHost
    #endif
  }

  @discardableResult
  func dispatch(_ action: WorkspaceAction, from: UUID? = nil) -> Bool {
    guard workIsCurrent(lifecycleGeneration) else { return false }
    guard let host = sourceHost(from), shortcutsAllowed(in: host), tabs.canPerform(action) else { return false }
    if action == .closeWindow || (action == .closeTerminal && tabs.closesWindow) {
      closeHost(host)
      return true
    }
    if action == .toggleTabBar { tabs.toggleTabBar(for: host); return true }
    if action == .alwaysOnTop {
      // The quick panel already floats permanently. Consume its shortcut
      // without revealing main, changing a preference, or emitting feedback.
      if hosts[host]?.kind == .quick { return true }
      return performOnWorkspace {
        self.tabs.apply(action)
        #if os(macOS)
        let enabled = self.tabs.quickTerminal.alwaysOnTop
        self.windowFeedback.show(title: "Always on Top",
          symbol: enabled ? "pin.fill" : "pin.slash", isStruckThrough: !enabled,
          accessibilityLabel: enabled ? "Always on Top: On" : "Always on Top: Off",
          in: self.workspaceHostID)
        #endif
      }
    }
    if action == .manageHosts || action == .inspector {
      return performOnWorkspace { self.tabs.apply(action) }
    }
    tabs.apply(action)
    refreshDialogs()
    return true
  }

  func submit(_ intent: WorkspaceIntent, from: UUID? = nil) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    if let from, !claim(from) { return }
    execute(intent)
  }

  func requestClose(_ id: UUID, from: UUID) {
    guard claim(from), shortcutsAllowed(in: from) else { return }
    tabs.requestClose(id)
    refreshDialogs()
  }

  func requestCloseFromTabBar(_ id: UUID, from: UUID) {
    guard claim(from), shortcutsAllowed(in: from) else { return }
    tabs.requestCloseFromTabBar(id)
    refreshDialogs()
  }

  @discardableResult
  func performOnWorkspace(_ action: () -> Void) -> Bool {
    guard workIsCurrent(lifecycleGeneration), !hasBlockingPresentation else { return false }
    #if os(macOS)
    guard let host = hosts[workspaceHostID], let window = host.window else { return false }
    if host.kind == .workspace {
      guard tabs.quickTerminal.revealWorkspace(window) else { return false }
      host.state.orderedIn = true
      host.state.miniaturized = false
      host.state.keyWithinHost = true
      _ = claim(workspaceHostID)
    }
    #endif
    action()
    return true
  }

  @discardableResult
  func showAccessory(_ pluginID: String, on tabID: UUID, from hostID: UUID? = nil) -> Bool {
    if let hostID, !claim(hostID) { return false }
    guard tabs.tabs.contains(where: { $0.id == tabID }) else { return false }
    return performOnWorkspace { tabs.showAccessory(pluginID, on: tabID) }
  }

  private func closeHost(_ id: UUID) {
    #if os(macOS)
    if hosts[id]?.kind == .quick { tabs.quickTerminal.hide() }
    else { hosts[id]?.window?.performClose(nil) }
    #endif
  }

  private func refreshMenuShortcuts() {
    let key = hosts.first { $0.value.state.eligible && $0.value.state.keyWithinHost }?.key
    tabs.menuShortcuts = key.map { shortcutsAllowed(in: $0) }
  }

  func refreshFrames() {
    let foreground = hosts.values.contains { $0.state.eligible && $0.state.renderVisible }
    for tab in tabs.tabs {
      tab.setPublishesFrames(foreground && (tab.id == tabs.selected || tabs.workspaceSplit?.ids.contains(tab.id) == true))
    }
  }

  private func observeModel() {
    guard started else { return }
    observationGeneration += 1
    let generation = observationGeneration
    withObservationTracking {
      _ = tabs.pendingClose
      _ = tabs.problem
      _ = tabs.passwordOffer
      _ = tabs.historyProblem
      _ = tabs.selected
      _ = tabs.workspaceSplit
      _ = tabs.tabs.map(\.isLive)
      _ = tabs.accessory
      _ = tabs.inspectorPlugin
      _ = registry.disabled
      _ = store.handoff.nearby.map(\.id)
      _ = store.handoff.receivedToken
      _ = store.hosts
      _ = connectRequests
      _ = notice
      _ = dialogPending?()
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.started, generation == self.observationGeneration else { return }
        self.modelChanged()
        self.observeModel()
      }
    }
    modelChanged()
  }

  private func modelChanged() {
    refreshFrames()
    refreshPlugins()
    tabs.takeOverReady = !store.handoff.nearby.isEmpty
    if let snapshot = store.handoff.takeReceived() { _ = tabs.prepareHandoff(snapshot, hosts: store.listed) }
    resumeSavedHandoff()
    refreshDialogs()
    refreshMenuShortcuts()
  }

  /// `shown` and `didDismiss` bracket the native surface, not the await.
  /// Entries withdrawn before reaching the screen never receive didDismiss.
  @discardableResult
  func askDialog(_ dialog: Dialog, in anchor: DialogAnchor? = nil,
                 shown: (@MainActor () -> Void)? = nil) async -> DialogReply? {
    let generation = lifecycleGeneration
    var afterRevision: Int?
    while workIsCurrent(generation) {
      do { try await waitForPresentationHost(generation: generation, after: afterRevision) }
      catch { return nil }
      guard workIsCurrent(generation) else { return nil }
      guard let lease = acquirePresentation() else { afterRevision = nil; continue }
      let revision = hostRevision
      var presented = false
      let reply = await DialogPresenter.ask(dialog, in: anchor ?? windowAnchor(for: lease.hostID), shown: {
        presented = true
        self.presentationDidPresent(lease)
        shown?()
      }, didDismiss: { self.presentationDidDismiss(lease) })
      if !presented { presentationDidDismiss(lease) }
      guard workIsCurrent(generation) else { return nil }
      if let reply { return reply }
      // Losing a host, including while queued in the native presenter, is not
      // the person's Cancel. Retry when a host reports availability again.
      afterRevision = presented ? nil : revision
    }
    return nil
  }

  private var presentationHostAvailable: Bool {
    guard let id = presentationOwner ?? effectiveHost, let host = hosts[id], host.state.eligible else { return false }
    #if os(macOS)
    if let window = host.window { return window.isVisible && !window.isMiniaturized }
    #endif
    return true
  }

  private func waitForPresentationHost(generation: Int, after revision: Int?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        guard workIsCurrent(generation) else { continuation.resume(throwing: CancellationError()); return }
        if presentationHostAvailable && (revision == nil || revision != hostRevision) {
          continuation.resume()
        } else {
          hostWaiters[id] = HostWaiter(generation: generation, afterRevision: revision, continuation: continuation)
        }
      }
    } onCancel: {
      Task { @MainActor in
        self.hostWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
      }
    }
  }

  private func resumeHostWaiters() {
    guard !stopped, presentationHostAvailable else { return }
    let ready = hostWaiters.filter {
      $0.value.generation == lifecycleGeneration && ($0.value.afterRevision == nil || $0.value.afterRevision != hostRevision)
    }.map(\.key)
    for id in ready { hostWaiters.removeValue(forKey: id)?.continuation.resume() }
  }

  func refreshDialogs() {
    guard started else { return }
    if let dialogTask {
      // An unrelated, higher-priority question cannot withdraw an input field
      // already in use. Only this request's own removal invalidates its task.
      if dialogPending?() == false { dialogTask.cancel() }
      return
    }
    guard !hasBlockingPresentation, let next = nextDialog() else { return }
    let token = UUID()
    let generation = lifecycleGeneration
    dialogToken = token
    dialogPending = next.pending
    dialogTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.dialogToken == token {
          self.dialogTask = nil
          self.dialogToken = nil
          self.dialogPending = nil
          self.refreshDialogs()
        }
      }
      guard self.workIsCurrent(generation) else { return }
      _ = await askDialog(next.dialog)
    }
  }

  private func nextDialog() -> (pending: @MainActor () -> Bool, dialog: Dialog)? {
    if let id = tabs.pendingClose {
      return ({ self.tabs.pendingClose == id }, Dialog.confirm(
        tabs.closeQuestion, message: tabs.closeNote, verb: tabs.pendingCloseVerb, role: .destructive,
        shortcuts: [tabs.closingWorkspaceID == nil ? .command("w") : .commandOption("w")],
        cancel: { self.tabs.cancelClose() }, perform: { self.tabs.confirmClose() }))
    }
    if let notice {
      return ({ self.notice?.id == notice.id }, Dialog.notice(notice.title, message: notice.message) { self.notice = nil })
    }
    if let request = connectRequests.first {
      return ({ self.connectRequests.contains { $0.id == request.id } }, ConnectionDialog.password(request,
        connect: { self.connect(request, password: $0) }, cancel: { self.cancelConnect(request) }))
    }
    if let report = tabs.problem {
      if report.problem.kind == .history {
        return ({ self.problemIsPending(report) }, Dialog(title: "Could Not Save Session History", message: report.problem.reason,
          actions: [Dialog.Action("OK") { _ in self.tabs.tabs.first { $0.id == report.tab }?.acknowledge() }]))
      }
      return ({ self.problemIsPending(report) }, ConnectionDialog.problem(report,
        close: { self.tabs.close(report.tab) },
        setAside: { self.tabs.tabs.first { $0.id == report.tab }?.setProblemAside() },
        again: { self.retry(report) }))
    }
    if let problem = tabs.historyProblem {
      return ({ self.tabs.historyProblem == problem }, Dialog(title: "Could Not Save Session History", message: problem,
        actions: [Dialog.Action("OK") { _ in self.tabs.historyProblem = nil }]))
    }
    if let offer = tabs.passwordOffer {
      return ({ self.tabs.tabs.first { $0.id == offer.tab }?.passwordOffer?.id == offer.offer.id }, ConnectionDialog.keep(offer, replacing: latest(offer.host).remembersPassword,
        keep: { self.keep(offer) }, decline: { self.tabs.answer(offer, kept: false) }))
    }
    return nil
  }

  private func problemIsPending(_ report: TabProblem) -> Bool {
    guard let tab = tabs.tabs.first(where: { $0.id == report.tab }), tab.problem?.id == report.problem.id else { return false }
    return report.problem.kind == .history || tab.problemRaised
  }
}
