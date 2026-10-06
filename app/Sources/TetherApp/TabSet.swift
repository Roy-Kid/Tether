import Foundation
import Observation
import SwiftUI
import Tether
import TetherPluginKit

struct WorkspaceEntry: Identifiable {
  let pluginID: String
  /// Host this workspace was opened from. `nil` for independent plugins.
  let hostID: UUID?
  let workspace: any PluginWorkspace
  var id: UUID { workspace.id }
}

/// Which tab plugin's accessory is open, and on which tab.
struct AccessoryRef: Equatable {
  let tab: SessionTab.ID
  let plugin: String
}

/// An enabled tab plugin's accessory, as the chrome draws it.
struct PluginAccessory: Identifiable {
  /// The plugin's ID.
  let id: String
  /// The plugin's name, for the menu that groups its commands.
  let title: String
  let accessory: TabAccessory
}

/// A sheet a tab plugin asked the window to present.
struct PluginSheet: Identifiable {
  let id = UUID()
  let tab: SessionTab.ID
  let plugin: String
  let view: AnyView
}

enum Palette: Equatable {
  case command
  case quickSwitch
}

enum WorkspaceIntent: Equatable {
  case newTerminal
  case splitTerminal(Bool)
  case restoreTab(UUID)
  case connect(Host)
  case edit(Host)
  case launchPlugin(String)
}

/// The open sessions, grouped by the host the window is showing.
@MainActor
@Observable
final class TabSet {
  let keyBindings = KeyBindingStore()
  var tabs: [SessionTab] = []
  var terminalWorkspaces: [UUID: TerminalWorkspace] = [:]
  var suppressPersistence = false
  var preparingHistoryIDs: Set<UUID> = []
  var splitInProgress = false
  var pendingSplit: (pane: UUID, vertical: Bool)?
  var visiblePaneIDs: Set<UUID> {
    if let workspace = currentWorkspace { return Set(workspace.maximized ? [workspace.focused] : workspace.layout.leaves) }
    return Set([selected].compactMap { $0 })
  }
  var currentWorkspace: TerminalWorkspace? { selected.flatMap { terminalWorkspaces[$0] } }
  func workspaceID(for pane: UUID) -> UUID? { terminalWorkspaces.first { $0.value.layout.leaves.contains(pane) }?.key }
  func focusPane(_ id: UUID) {
    guard let key = workspaceID(for: id), let workspace = terminalWorkspaces[key] else { return }
    if selected == key && workspace.focused == id { return }
    selected = key
    workspace.focused = id
    currentHost = workspace.host
    accessory = nil
    persistHistory()
  }
  func prepareSplit(_ vertical: Bool) {
    guard let current, pendingSplit == nil, !splitInProgress else { return }
    splitInProgress = true
    pendingSplit = (current.id, vertical)
    intent = .splitTerminal(vertical)
  }
  /// Recent user closes, newest last; persisted when a history store is supplied.
  var closedTabs: [ClosedTerminal] = []
  var restoringTab: UUID?
  static let closedTabLimit = 20
  var extensions: [WorkspaceEntry] = []
  var selected: SessionTab.ID?
  var currentHost: Host?
  var zen = false
  private(set) var tabBarVisible: Bool {
    didSet {
      if tabBarVisible != oldValue {
        defaults.set(tabBarVisible, forKey: TabBarPreference.key)
      }
    }
  }
  var inspector = false
  var hostPicker = false
  var manageHosts = false
  var tabMenu: SessionTab.ID?
  var accessory: AccessoryRef?
  /// The tab plugin whose attachment the inspector shows, on whichever tab
  /// is selected. By plugin rather than by tab: switching tabs keeps the
  /// inspector on the same kind of thing, for the tab now in front.
  var inspectorPlugin: String?
  var sheet: PluginSheet?
  /// Every enabled tab plugin, in registration order. A click on the
  /// selected tab opens the first picker. An inspector is a button on the
  /// status bar, not something a tab click toggles.
  var accessories: [PluginAccessory] = []
  var palette: Palette?
  var closingWorkspace: UUID?
  var workspaceCloseNotes: [String] = []
  var pendingClose: SessionTab.ID?
  private(set) var checkingClose: SessionTab.ID?
  private var closeCheck: Task<Void, Never>?
  private var closeActivity: ShellActivity = .idle
  private let inspectActivity: @MainActor (SessionTab) async -> ShellActivity
  var renaming: SessionTab.ID?
  var intent: WorkspaceIntent?
  var paletteQuery = ""

  /// The accepted host keys, shared by every session: trust belongs to the
  /// person and their machine, not to one tab.
  var known = KnownHosts()

  /// Hosts whose working password a person chose not to keep, this run.
  private var keepDeclined: Set<UUID> = []

  private var lastByHost: [UUID: UUID] = [:]
  private var recents: [UUID] = []
  private var inspectorBeforeZen = false
  private var terminalSerial: [UUID: Int] = [:]
  private let defaults: UserDefaults
  private let historyStore: SessionHistoryStore?
  var historyProblem: String?
  private var reportedHistoryProblem: String?

  init(
    defaults: UserDefaults = .standard,
    historyStore: SessionHistoryStore? = nil,
    inspectActivity: @escaping @MainActor (SessionTab) async -> ShellActivity = {
      await $0.activityForClose()
    }
  ) {
    self.defaults = defaults
    self.historyStore = historyStore
    closedTabs = historyStore?.load() ?? []
    historyProblem = historyStore?.problem
    reportedHistoryProblem = historyStore?.problem
    self.inspectActivity = inspectActivity
    tabBarVisible = defaults.object(forKey: TabBarPreference.key) as? Bool
      ?? TabBarPreference.default
  }

  var current: SessionTab? {
    tabs.first { $0.id == (currentWorkspace?.focused ?? selected) }
  }

  var currentExtension: (any PluginWorkspace)? {
    extensions.first { $0.id == selected }?.workspace
  }

  var visibleTabs: [SessionTab] {
    guard let currentHost else { return [] }
    return tabs.filter { terminalWorkspaces[$0.id]?.host.id == currentHost.id || (terminalWorkspaces[$0.id] == nil && workspaceID(for: $0.id) == nil && $0.host.id == currentHost.id) }
  }

  var visibleExtensions: [WorkspaceEntry] {
    extensions.filter { entry in
      entry.hostID == nil || entry.hostID == currentHost?.id
    }
  }

  var visibleIDs: [UUID] {
    visibleTabs.map(\.id) + visibleExtensions.map(\.id)
  }

  var recentHostIDs: [UUID] { recents }

  var showsTabBar: Bool { tabBarVisible && !zen }

  func open(_ host: Host, password: String, typedNow: Bool = false) {
    show(host)
    adopt(SessionTab(host: host, password: password, typedNow: typedNow, known: known, name: nextName(for: host), directory: pendingSplit.flatMap { pending in tabs.first { $0.id == pending.pane }?.workingDirectory }))
  }

  /// Opens a new terminal on a connection that is already authenticated.
  func open(_ host: Host, on connection: RemoteConnection) {
    show(host)
    adopt(SessionTab(host: host, connection: connection, known: known, name: nextName(for: host), directory: pendingSplit.flatMap { pending in tabs.first { $0.id == pending.pane }?.workingDirectory }))
  }

  /// The authenticated lease for this host, if one is already in hand.
  ///
  /// A live tab has it. A tab still handshaking will have it once that
  /// finishes, and waiting is how two "New Terminal"s share one login
  /// instead of asking for a password twice.
  func lease(for host: Host) async throws -> RemoteConnection? {
    guard host.allowsConnectionReuse else { return nil }
    if let tab = tabs.first(where: { $0.host == host && $0.connection != nil }),
      let connection = tab.connection
    {
      return connection
    }
    if let pending = tabs.first(where: { $0.host == host && $0.isHandshaking }) {
      return try await pending.connectionReady()
    }
    return nil
  }

  private func nextName(for host: Host) -> String {
    let next = (terminalSerial[host.id] ?? 0) + 1
    terminalSerial[host.id] = next
    return "Terminal \(next)"
  }

  func prepareHistory(_ tab: SessionTab) {
    if let historyStore, historyStore.canWrite {
      let restoring = tab.historyID != nil
      let id = tab.historyID ?? UUID()
      do {
        tab.history = try SessionHistory(directory: historyStore.location(id),
          lineLimit: HistoryPreference.limit(in: defaults), restoring: restoring)
        tab.historyID = id
        preparingHistoryIDs.insert(id)
      } catch { reportHistoryProblem("Could not save session history: \(error.localizedDescription)") }
      tab.onHistoryChanged = { [weak self, weak tab] in
        guard let self, let tab else { return }
        if let workspace = self.terminalWorkspaces[tab.id], workspace.layout.leaves.count == 1 { workspace.name = tab.name }
        self.persistHistory()
      }
    }
  }

  func adopt(_ tab: SessionTab, at index: Int? = nil) {
    if tab.history == nil && tab.historyID == nil { prepareHistory(tab) }
    if pendingSplit == nil { show(tab.host) }
    tab.offersToSave = !keepDeclined.contains(tab.host.id)
    // A person who declined a question the login asked has closed it.
    let id = tab.id
    tab.onDeclined = { [weak self] in self?.close(id, remember: false) }
    tabs.insert(tab, at: min(max(index ?? tabs.count, 0), tabs.count))
    if let split = pendingSplit, let groupID = workspaceID(for: split.pane), let workspace = terminalWorkspaces[groupID] {
      workspace.layout = workspace.layout.splitting(split.pane, adding: tab.id, vertical: split.vertical)
      workspace.focused = tab.id
      workspace.maximized = false
      selected = groupID
      pendingSplit = nil
    } else {
      terminalWorkspaces[tab.id] = TerminalWorkspace(tab)
      select(tab.id)
    }
    if let historyID = tab.historyID { preparingHistoryIDs.remove(historyID) }
    persistHistory()
  }

  func discardPrepared(_ pane: SessionTab) {
    pane.onHistoryChanged = nil
    if let id = pane.historyID { preparingHistoryIDs.remove(id) }
    pane.close()
  }

  func replacePane(_ source: SessionTab, with replacement: SessionTab) {
    guard let key = workspaceID(for: source.id), let workspace = terminalWorkspaces[key],
      let index = tabs.firstIndex(where: { $0.id == source.id }) else { discardPrepared(replacement); return }
    workspace.layout = workspace.layout.remapping([source.id: replacement.id])
    workspace.focused = replacement.id
    replacement.onDeclined = { [weak self] in self?.close(replacement.id, remember: false) }
    tabs[index] = replacement
    source.onHistoryChanged = nil
    source.close()
    if key == source.id {
      terminalWorkspaces.removeValue(forKey: key)
      terminalWorkspaces[replacement.id] = workspace
      selected = replacement.id
    }
    if let id = replacement.historyID { preparingHistoryIDs.remove(id) }
    persistHistory()
  }

  var visibleWorkspaceRoots: [SessionTab] { tabs.filter { terminalWorkspaces[$0.id] != nil || workspaceID(for: $0.id) == nil } }
  func rootRecord(_ tab: SessionTab, index: Int) -> ClosedTerminal {
    guard let workspace = terminalWorkspaces[tab.id] else { return ClosedTerminal(tab, index: index) }
    return ClosedTerminal(workspace: workspace, root: tab, panes: tabs.filter { workspace.layout.leaves.contains($0.id) }, index: index)
  }
  func persistHistory() {
    guard !suppressPersistence else { return }
    historyStore?.save(open: visibleWorkspaceRoots.enumerated().map { rootRecord($0.element, index: $0.offset) }, closed: closedTabs, retaining: preparingHistoryIDs)
    if let problem = historyStore?.problem { reportHistoryProblem(problem) }
  }

  private func reportHistoryProblem(_ message: String) {
    guard reportedHistoryProblem != message else { return }
    reportedHistoryProblem = message
    historyProblem = message
  }

  func checkpointHistory() {
    tabs.forEach { $0.checkpointHistory() }
    persistHistory()
  }

  /// The first tab with something to tell the person.
  var problem: TabProblem? {
    tabs.lazy.compactMap { tab in
      tab.problem.map { TabProblem(tab: tab.id, host: tab.host, problem: $0) }
    }.first
  }

  /// The first password that worked and could be kept.
  var passwordOffer: TabPasswordOffer? {
    tabs.lazy.compactMap { tab in
      tab.passwordOffer.map { TabPasswordOffer(tab: tab.id, host: tab.host, offer: $0) }
    }.first
  }

  /// Settles an offer. A no holds for the host for the rest of this run, so
  /// a person who keeps no passwords is asked once, not on every login.
  func answer(_ offer: TabPasswordOffer, kept: Bool) {
    if !kept {
      keepDeclined.insert(offer.host.id)
      for tab in tabs where tab.host.id == offer.host.id { tab.offersToSave = false }
    }
    tabs.first { $0.id == offer.tab }?.settlePasswordOffer()
  }

  /// Switch the window to this host, restoring its last tab. Does not connect.
  func show(_ host: Host) {
    if let current = currentHost, current.id != host.id {
      lastByHost[current.id] = selected
    }
    currentHost = host
    remember(host.id)
    if let restored = lastByHost[host.id], visibleIDs.contains(restored) {
      selected = restored
    } else {
      selected = visibleIDs.last
    }
  }

  func select(_ id: UUID) {
    if let key = workspaceID(for: id), key != id { focusPane(id); tabMenu = nil; return }
    selected = id
    if let tab = tabs.first(where: { $0.id == id }) {
      currentHost = terminalWorkspaces[id]?.host ?? tab.host
      lastByHost[currentHost!.id] = id
    } else if let host = currentHost {
      lastByHost[host.id] = id
    }
    tabMenu = nil
    if let accessory, accessory.tab != id { self.accessory = nil }
  }

  /// First click on another tab selects it; click the active tab to open its menu.
  func handleTabClick(_ id: UUID) {
    if selected == id {
      if let tab = current {
        if let picker = accessories.first(where: { $0.accessory.placement == .popover }),
          tab.canOpen(picker.id)
        {
          toggleAccessory(picker.id, on: id)
        }
      } else {
        tabMenu = tabMenu == id ? nil : id
      }
    } else {
      select(id)
    }
  }

  func openTabMenu(_ id: UUID) {
    select(id)
    revealTabBar()
    tabMenu = id
  }

  func toggleAccessory(_ pluginID: String, on id: UUID) {
    select(id)
    #if os(macOS)
      if placement(of: pluginID) == .inspector {
        toggleInspector(of: pluginID)
        return
      }
    #endif
    let wanted = AccessoryRef(tab: id, plugin: pluginID)
    accessory = accessory == wanted ? nil : wanted
    if accessory != nil { revealTabBar() }
  }

  /// Brings a plugin's accessory up on a tab without closing it if it is
  /// already there: something asked from the terminal wants to be seen.
  func showAccessory(_ pluginID: String, on id: UUID) {
    #if os(macOS)
      if placement(of: pluginID) == .inspector {
        if !isShowingInspector(of: pluginID) { toggleAccessory(pluginID, on: id) }
        return
      }
    #endif
    select(id)
    revealTabBar()
    accessory = AccessoryRef(tab: id, plugin: pluginID)
  }

  func placement(of pluginID: String) -> TabAccessory.Placement {
    accessories.first { $0.id == pluginID }?.accessory.placement ?? .popover
  }

  /// Whether the inspector is on screen and showing this plugin.
  func isShowingInspector(of pluginID: String) -> Bool {
    inspector && !zen && inspectorPlugin == pluginID
  }

  /// Shows the plugin in the inspector, or closes the inspector if it
  /// already is. Leaves zen, whose point is that the inspector is hidden:
  /// asking for something in it is asking to leave.
  private func toggleInspector(of pluginID: String) {
    if isShowingInspector(of: pluginID) {
      inspector = false
      inspectorPlugin = nil
      return
    }
    if zen { toggleZen() }
    accessory = nil
    inspectorPlugin = pluginID
    inspector = true
  }

  /// Fires when a close leaves no tab and no extension workspace. The app
  /// decides whether that means staying on the empty window.
  var onEmptied: (() -> Void)?

  func shutdown() {
    checkpointHistory()
    tabs.forEach { $0.onHistoryChanged = nil; $0.close() }
    extensions.forEach { $0.workspace.close() }
  }

  func closeAll() {
    closedTabs.removeAll()
    restoringTab = nil
    if case .restoreTab = intent { intent = nil }
    closeCheck?.cancel()
    closeCheck = nil
    checkingClose = nil
    tabs.forEach { $0.close() }
    extensions.forEach { $0.workspace.close() }
    tabs.removeAll()
    preparingHistoryIDs.removeAll()
    terminalWorkspaces.removeAll()
    pendingSplit = nil
    extensions.removeAll()
    selected = nil
    currentHost = nil
    lastByHost = [:]
    recents = []
    persistHistory()
    tabMenu = nil
    accessory = nil
    sheet = nil
    pendingClose = nil
    closingWorkspace = nil
    workspaceCloseNotes = []
  }

  /// Everything a plugin has open, closed before it is turned off.
  func closePlugin(_ pluginID: String) {
    for entry in extensions.filter({ $0.pluginID == pluginID }) { close(entry.id) }
    if accessory?.plugin == pluginID { accessory = nil }
    if inspectorPlugin == pluginID { inspectorPlugin = nil }
    if sheet?.plugin == pluginID { sheet = nil }
    for tab in tabs { tab.detach(pluginID) }
  }

  func canSplit(vertical: Bool) -> Bool {
    guard pendingSplit == nil, !splitInProgress, let workspace = currentWorkspace, let frame = workspace.paneFrames[workspace.focused] else { return false }
    return vertical ? frame.height >= 205 : frame.width >= 325
  }
  func movePaneFocus(dx: Double, dy: Double) {
    guard let workspace = currentWorkspace, !workspace.maximized, let source = workspace.paneFrames[workspace.focused] else { return }
    let target = workspace.layout.leaves.filter { $0 != workspace.focused }.compactMap { id -> (UUID, Double)? in
      guard let frame = workspace.paneFrames[id] else { return nil }
      let x = Double(frame.midX - source.midX), y = Double(frame.midY - source.midY)
      guard dx != 0 ? x * dx > 1 : y * -dy > 1 else { return nil }
      return (id, x * x + y * y)
    }.min { $0.1 < $1.1 }
    if let target { focusPane(target.0) }
  }
  func requestCloseWorkspace(_ id: UUID) {
    guard let workspace = terminalWorkspaces[id], workspace.layout.leaves.count > 1 else { requestClose(id); return }
    guard pendingClose == nil, checkingClose == nil else { return }
    checkingClose = id
    workspaceCloseNotes = []
    closeCheck = Task { [weak self] in
      guard let self else { return }
      for paneID in workspace.layout.leaves {
        guard let pane = self.tabs.first(where: { $0.id == paneID }) else { continue }
        let activity = pane.isLive ? await self.inspectActivity(pane) : .idle
        if let note = activity.closeMessage { self.workspaceCloseNotes.append(pane.title + ": " + note) }
        self.workspaceCloseNotes += pane.attachments.compactMap(\.attachment.closeNote)
        if pane.attachments.contains(where: { $0.attachment.requiresCloseConfirmation }), self.workspaceCloseNotes.isEmpty {
          self.workspaceCloseNotes.append(pane.title)
        }
      }
      guard !Task.isCancelled, self.checkingClose == id else { return }
      self.checkingClose = nil
      self.closeCheck = nil
      if self.workspaceCloseNotes.isEmpty { self.closeWorkspace(id) }
      else { self.closingWorkspace = id; self.pendingClose = id }
    }
  }
  func closeWorkspace(_ id: UUID) {
    guard let workspace = terminalWorkspaces[id], let root = tabs.first(where: { $0.id == id }) else { close(id); return }
    let index = visibleWorkspaceRoots.firstIndex(where: { $0.id == id }) ?? 0
    closedTabs.append(rootRecord(root, index: index))
    closedTabs = Array(closedTabs.suffix(Self.closedTabLimit))
    let ids = workspace.layout.leaves
    suppressPersistence = true
    for pane in ids { close(pane, remember: false) }
    suppressPersistence = false
    persistHistory()
  }

  /// Checks for work before closing a terminal. Open selectors dismiss first.
  func requestClose(_ id: SessionTab.ID) {
    if tabMenu == id {
      tabMenu = nil
      return
    }
    if accessory?.tab == id {
      accessory = nil
      return
    }
    guard pendingClose == nil, checkingClose != id else { return }
    closeCheck?.cancel()
    closeCheck = nil
    checkingClose = nil
    closeActivity = .idle
    guard let tab = tabs.first(where: { $0.id == id }) else {
      if extensions.contains(where: { $0.id == id }) { pendingClose = id }
      return
    }
    guard tab.isLive else {
      finishCloseRequest(id, activity: .idle)
      return
    }
    checkingClose = id
    let inspect = inspectActivity
    closeCheck = Task { [weak self] in
      let activity = await inspect(tab)
      guard !Task.isCancelled, let self, self.checkingClose == id else { return }
      self.checkingClose = nil
      self.closeCheck = nil
      self.finishCloseRequest(id, activity: tab.isLive ? activity : .idle)
    }
  }

  private func finishCloseRequest(_ id: SessionTab.ID, activity: ShellActivity) {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    let pluginIsBusy = tab.attachments.contains { $0.attachment.requiresCloseConfirmation }
    if activity == .idle && !pluginIsBusy {
      close(id)
    } else {
      closeActivity = activity
      pendingClose = id
    }
  }

  /// The confirmation's title: what is being closed, and the verb.
  var closeQuestion: String {
    guard let id = pendingClose else { return "Close?" }
    let name =
      tabs.first { $0.id == id }?.title
      ?? extensions.first { $0.id == id }?.workspace.title
    guard let name, !name.isEmpty else { return "Close?" }
    return "Close \(name)?"
  }

  /// Why closing needs confirmation, followed by any plugin consequences.
  var closeNote: String? {
    if closingWorkspace != nil { return workspaceCloseNotes.joined(separator: "\n\n") }
    guard let tab = tabs.first(where: { $0.id == pendingClose }) else { return nil }
    let notes = [closeActivity.closeMessage].compactMap { $0 }
      + tab.attachments.compactMap(\.attachment.closeNote)
    return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
  }

  func requestCloseSelected() {
    if palette != nil {
      palette = nil
      return
    }
    if hostPicker {
      hostPicker = false
      return
    }
    if accessory != nil {
      accessory = nil
      return
    }
    if tabMenu != nil {
      tabMenu = nil
      return
    }
    guard let selected else { return }
    requestClose(current?.id ?? selected)
  }

  func cancelClose() {
    pendingClose = nil
    closingWorkspace = nil
    workspaceCloseNotes = []
  }

  func confirmClose() {
    guard let id = pendingClose else { return }
    pendingClose = nil
    if closingWorkspace == id { closeWorkspace(id) } else { close(id) }
    closingWorkspace = nil
  }

  func close(_ id: SessionTab.ID, remember: Bool = true) {
    if checkingClose == id {
      closeCheck?.cancel()
      closeCheck = nil
      checkingClose = nil
    }
    if tabMenu == id { tabMenu = nil }
    if accessory?.tab == id { accessory = nil }
    if sheet?.tab == id { sheet = nil }
    if pendingClose == id { pendingClose = nil }
    if renaming == id { renaming = nil }

    if let index = extensions.firstIndex(where: { $0.id == id }) {
      extensions[index].workspace.close()
      extensions.remove(at: index)
      if selected == id { selected = visibleIDs.last }
      noteIfEmpty()
      return
    }
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let groupID = workspaceID(for: id)
    let workspace = groupID.flatMap { terminalWorkspaces[$0] }
    let hostID = workspace?.host.id ?? tabs[index].host.id
    if remember {
      let position = groupID.flatMap { key in visibleWorkspaceRoots.firstIndex(where: { $0.id == key }) } ?? index
      var record = ClosedTerminal(tabs[index], index: position)
      if let workspace, workspace.layout.leaves.count > 1, let sibling = workspace.layout.sibling(of: id) {
        record.parentID = workspace.id
        record.neighbor = sibling.node.leaves.first
        record.neighborPanes = sibling.node.leaves
        record.splitVertical = sibling.vertical
        record.splitBefore = sibling.before
        record.splitRatio = sibling.ratio
      }
      if let workspace, workspace.layout.leaves.count == 1 { record = ClosedTerminal(workspace: workspace, root: tabs[index], panes: [tabs[index]], index: position) }
      closedTabs.append(record)
      if closedTabs.count > Self.closedTabLimit,
        let oldest = closedTabs.firstIndex(where: { $0.id != restoringTab }) {
        closedTabs.remove(at: oldest)
      }
    }
    tabs[index].close()
    if let error = tabs[index].history?.error { reportHistoryProblem(error) }
    tabs.remove(at: index)
    if let groupID, let workspace {
      if let remaining = workspace.layout.removing(id) {
        workspace.layout = remaining
        workspace.focused = remaining.leaves.first!
        workspace.maximized = false
        if groupID == id {
          terminalWorkspaces.removeValue(forKey: groupID)
          terminalWorkspaces[workspace.focused] = workspace
          if selected == groupID { selected = workspace.focused }
        }
      } else { terminalWorkspaces.removeValue(forKey: groupID) }
    }
    persistHistory()

    // Stay on this host even when the last tab closes. Jumping to another
    // machine is a choice, not a side effect of tidying.
    if selected == id && terminalWorkspaces[id] == nil {
      let remaining = visibleTabs.filter { (terminalWorkspaces[$0.id]?.host.id ?? $0.host.id) == hostID }.map(\.id)
        + extensions.filter { $0.hostID == hostID || $0.hostID == nil }.map(\.id)
      selected = remaining.last
      if let host = currentHost {
        lastByHost[host.id] = selected
      }
    }
    noteIfEmpty()
  }

  /// The window is empty only when nothing remains anywhere, including a tab
  /// that belongs to another host. Closing the last tab on this host still
  /// leaves "No open terminals" without ending the app.
  private func noteIfEmpty() {
    guard tabs.isEmpty, extensions.isEmpty else { return }
    onEmptied?()
  }

  func toggleZen() {
    if zen {
      zen = false
      inspector = inspectorBeforeZen
    } else {
      inspectorBeforeZen = inspector
      inspector = false
      zen = true
    }
  }

  func toggleInspector() {
    guard !zen else { return }
    inspector.toggle()
  }

  func toggleTabBar() {
    if zen {
      revealTabBar()
    } else {
      tabBarVisible.toggle()
      if !tabBarVisible {
        tabMenu = nil
        accessory = nil
      }
    }
  }

  /// A popover needs a visible tab to anchor to, including when opened by
  /// a command or a terminal link while the tab bar is hidden.
  private func revealTabBar() {
    #if os(macOS)
      if zen { toggleZen() }
      tabBarVisible = true
    #endif
  }

  func openPalette(_ kind: Palette) {
    paletteQuery = ""
    palette = kind
    hostPicker = false
    tabMenu = nil
    accessory = nil
  }

  func cycleTab(forward: Bool) {
    let ids = visibleIDs
    guard !ids.isEmpty else { return }
    let current = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
    let next = forward ? (current + 1) % ids.count : (current - 1 + ids.count) % ids.count
    select(ids[next])
  }

  /// Answers the rename question either way: an empty name keeps the old one.
  func rename(_ id: UUID, to name: String) {
    if renaming == id { renaming = nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let tab = tabs.first(where: { $0.id == id }) else { return }
    if let key = workspaceID(for: id), let workspace = terminalWorkspaces[key] {
      workspace.name = trimmed
      if workspace.layout.leaves.count == 1 { tabs.first(where: { $0.id == key })?.name = trimmed }
    } else { tab.name = trimmed }
    persistHistory()
  }

  /// A word only when the green dot is not enough. Connected is the
  /// default: the host name and the tab already say where you are.
  func statusLine() -> String {
    if currentExtension != nil { return "" }
    guard let tab = current else {
      return currentHost == nil ? "" : "No open terminals"
    }
    if let shown = tab.shown {
      return shown.isDisconnected ? "Disconnected" : ""
    }
    return switch tab.stage {
    case .connecting: "Connecting"
    case .asking: "Needs authentication"
    case .connected: ""
    case .failed: "Disconnected"
    case .ended: "Ended"
    }
  }

  func isLive(host: Host) -> Bool {
    tabs.contains { $0.host == host && $0.isLive }
  }

  func connectedHosts(in listed: [Host]) -> [Host] {
    listed.filter { isLive(host: $0) }
  }

  func recentHosts(in listed: [Host]) -> [Host] {
    recents.compactMap { id in listed.first { $0.id == id } }
  }

  /// Host picker subtitle: where the host is, and which tab/session is open.
  func workspaceCaption(for host: Host) -> String {
    let owned = tabs.filter { $0.host.id == host.id }
    let preferred = lastByHost[host.id].flatMap { id in owned.first { $0.id == id } }
    let tab = preferred ?? owned.last
    let place = host.isLocal ? "Local machine" : host.address
    guard let tab else { return place }
    if tab.shown != nil {
      return "\(place) · \(tab.title) / \(tab.subtitle)"
    }
    return "\(place) · \(tab.title)"
  }

  func openExtension(_ workspace: any PluginWorkspace, pluginID: String, hostID: UUID?) {
    extensions.append(WorkspaceEntry(pluginID: pluginID, hostID: hostID, workspace: workspace))
    select(workspace.id)
  }

  private func remember(_ id: UUID) {
    recents.removeAll { $0 == id }
    recents.insert(id, at: 0)
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
