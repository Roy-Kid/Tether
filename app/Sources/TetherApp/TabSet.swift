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

/// A workspace tab owns shells and its own presentation, independently of plugins.
struct TerminalWorkspace: Identifiable {
  let id: UUID
  let host: Host
  var name: String
  var terminalIDs: [UUID]
  var focused: UUID
  var layout: WorkspaceSplit?
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
  case newTab
  case addTerminal(UUID)
  case splitTerminal(UUID, SplitDirection)
  case restoreTab(UUID)
  case connect(Host)
  case edit(Host)
  case launchPlugin(String)
  /// Dial a disconnected terminal again, in place.
  case reconnect(UUID)
}

/// The open sessions, grouped by the host the window is showing.
@MainActor
@Observable
final class TabSet {
  let keyBindings = KeyBindingStore()
  #if os(macOS)
    let quickTerminal: QuickTerminalController
  #endif
  var tabs: [SessionTab] = []
  var workspaces: [TerminalWorkspace] = []
  var renamingWorkspace: UUID?
  private var closingWorkspace: UUID?
  var closingWorkspaceID: UUID? { closingWorkspace }
  private var workspaceCloseNotes: [String] = []
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
  /// Whether the window has room for a second column — the inspector, or
  /// terminals side by side. Always on a Mac; an iPad says so from its size
  /// classes, and a phone, even turned sideways, never has it.
  var wide = true
  var hostPicker = false
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
  var pendingClose: SessionTab.ID?
  private(set) var checkingClose: SessionTab.ID?
  private var closeCheck: Task<Void, Never>?
  private var closeActivity: ShellActivity = .idle
  private let inspectActivity: @MainActor (SessionTab) async -> ShellActivity
  var renaming: SessionTab.ID?
  var intent: WorkspaceIntent?
  /// How many times the window has been asked to close itself. A count, not
  /// a flag: the window answers each new one, and two in a row are two.
  private(set) var windowCloseRequests = 0
  /// Whether the workspace window takes the menu's shortcuts: true when it
  /// is key and free of sheets, false when key but busy, nil while another
  /// window is key — Settings, say — so ⌘W there closes that one. Kept
  /// here because the menu cannot see the window's focus: the workspace is
  /// hosted in an AppKit window, not a scene.
  var menuShortcuts: Bool?
  var paletteQuery = ""

  /// The accepted host keys, shared by every session: trust belongs to the
  /// person and their machine, not to one tab.
  var known = KnownHosts()

  /// Hosts whose working password a person chose not to keep, this run.
  private var keepDeclined: Set<UUID> = []

  var currentWorkspace: TerminalWorkspace? {
    guard let selected else { return nil }
    return workspace(containing: selected)
  }

  var selectedWorkspaceID: UUID? { currentWorkspace?.id ?? selected }

  func workspace(containing terminal: UUID) -> TerminalWorkspace? {
    workspaces.first { $0.terminalIDs.contains(terminal) }
  }

  var visibleWorkspaces: [TerminalWorkspace] {
    workspaces.filter { $0.host.id == currentHost?.id }
  }

  var currentTerminals: [SessionTab] {
    guard let workspace = currentWorkspace else { return [] }
    return workspace.terminalIDs.compactMap { id in tabs.first { $0.id == id } }
  }

  var workspaceSplit: WorkspaceSplit? { currentWorkspace?.layout }

  func split(_ newTab: SessionTab, beside id: UUID, direction: SplitDirection) {
    guard let source = tabs.first(where: { $0.id == id }),
      source.host.id == newTab.host.id, let page = workspace(containing: id) else {
      newTab.close()
      return
    }
    let layout = page.layout ?? .tab(id)
    let base = layout.ids.contains(id) ? layout : layout.replacing(page.focused, with: .tab(id))
    adopt(newTab, in: page.id)
    if let index = workspaces.firstIndex(where: { $0.id == page.id }) {
      let panes: WorkspaceSplit
      switch direction {
      case .left, .up: panes = .split(direction, .tab(newTab.id), .tab(id))
      case .right, .down: panes = .split(direction, .tab(id), .tab(newTab.id))
      }
      workspaces[index].layout = base.replacing(id, with: panes)
    }
    persistHistory()
  }

  func splitTerminal(_ id: UUID, direction: SplitDirection, on connection: RemoteConnection? = nil) {
    guard let source = tabs.first(where: { $0.id == id }) else { return }
    let host = source.host
    let tab: SessionTab
    if let connection {
      tab = SessionTab(host: host, connection: connection, known: known, name: nextName(for: host))
    } else {
      guard host.isLocal else { return }
      tab = SessionTab(host: host, password: "", known: known, name: nextName(for: host))
    }
    split(tab, beside: id, direction: direction)
  }

  func joinSplits() {
    guard let page = currentWorkspace,
      let index = workspaces.firstIndex(where: { $0.id == page.id }) else { return }
    workspaces[index].layout = nil
    persistHistory()
  }

  private func removeSplitTab(_ id: UUID) {
    guard let index = workspaces.firstIndex(where: { $0.terminalIDs.contains(id) }) else { return }
    workspaces[index].terminalIDs.removeAll { $0 == id }
    let remaining = workspaces[index].layout?.removing(id)
    workspaces[index].layout = (remaining?.ids.count ?? 0) > 1 ? remaining : nil
    if workspaces[index].terminalIDs.isEmpty {
      workspaces.remove(at: index)
    } else if workspaces[index].focused == id {
      let next = remaining?.ids.first ?? workspaces[index].terminalIDs[0]
      workspaces[index].focused = next
      if selected == id { selected = next }
      if lastByHost[workspaces[index].host.id] == id { lastByHost[workspaces[index].host.id] = next }
    }
  }

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
    #if os(macOS)
      quickTerminal = QuickTerminalController(defaults: defaults)
    #endif
    self.historyStore = historyStore
    closedTabs = historyStore?.load() ?? []
    historyProblem = historyStore?.problem
    reportedHistoryProblem = historyStore?.problem
    self.inspectActivity = inspectActivity
    tabBarVisible = defaults.object(forKey: TabBarPreference.key) as? Bool
      ?? TabBarPreference.default
  }

  var current: SessionTab? {
    tabs.first { $0.id == selected }
  }

  var currentExtension: (any PluginWorkspace)? {
    extensions.first { $0.id == selected }?.workspace
  }

  var visibleTabs: [SessionTab] {
    guard let currentHost else { return [] }
    return tabs.filter { $0.host.id == currentHost.id }
  }

  var visibleExtensions: [WorkspaceEntry] {
    extensions.filter { entry in
      entry.hostID == nil || entry.hostID == currentHost?.id
    }
  }

  var visibleIDs: [UUID] {
    visibleWorkspaces.map(\.id) + visibleExtensions.map(\.id)
  }

  var recentHostIDs: [UUID] { recents }

  var showsTabBar: Bool { tabBarVisible && !zen }

  func open(_ host: Host, password: String, typedNow: Bool = false, in workspaceID: UUID? = nil) {
    show(host)
    adopt(SessionTab(host: host, password: password, typedNow: typedNow, known: known, name: nextName(for: host)), in: workspaceID)
  }

  /// Opens a new terminal on a connection that is already authenticated.
  func open(_ host: Host, on connection: RemoteConnection, in workspaceID: UUID? = nil) {
    show(host)
    adopt(SessionTab(host: host, connection: connection, known: known, name: nextName(for: host)), in: workspaceID)
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

  func adopt(_ tab: SessionTab, at index: Int? = nil, in workspaceID: UUID? = nil) {
    if let workspaceID {
      if checkingClose == workspaceID { cancelClose() }
      guard let page = workspaces.first(where: { $0.id == workspaceID }),
        page.host.id == tab.host.id else { tab.close(); return }
    }
    if let historyStore, historyStore.canWrite {
      let restoring = tab.historyID != nil
      let id = tab.historyID ?? UUID()
      do {
        tab.history = try SessionHistory(directory: historyStore.location(id),
          lineLimit: HistoryPreference.limit(in: defaults), restoring: restoring)
        tab.historyID = id
      } catch { reportHistoryProblem("Could not save session history: \(error.localizedDescription)") }
      tab.onHistoryChanged = { [weak self] in self?.persistHistory() }
    }
    show(tab.host)
    tab.offersToSave = !keepDeclined.contains(tab.host.id)
    // A person who declined a question the login asked has closed it.
    let id = tab.id
    tab.onDeclined = { [weak self] in self?.close(id, remember: false) }
    tabs.insert(tab, at: min(max(index ?? tabs.count, 0), tabs.count))
    if let workspaceID, let page = workspaces.firstIndex(where: { $0.id == workspaceID }) {
      workspaces[page].terminalIDs.append(tab.id)
    } else {
      let page = TerminalWorkspace(id: UUID(), host: tab.host, name: "Tab \(visibleWorkspaces.count + 1)",
        terminalIDs: [tab.id], focused: tab.id)
      workspaces.insert(page, at: min(max(index ?? workspaces.count, 0), workspaces.count))
    }
    select(tab.id)
    persistHistory()
  }

  func persistHistory() {
    historyStore?.save(open: workspaces.enumerated().compactMap { snapshot($0.element, index: $0.offset) }, closed: closedTabs)
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

  /// The first tab with something to tell the person now.
  ///
  /// A failure in a terminal the person is not looking at is marked on its
  /// tab, not put in front of the one they are (spec §5); and a lost
  /// connection is asked about only once they act on it.
  var problem: TabProblem? {
    tabs.lazy.compactMap { tab -> TabProblem? in
      guard let problem = tab.problem else { return nil }
      if problem.kind != .history {
        guard tab.problemRaised, tab.id == self.current?.id else { return nil }
      }
      return TabProblem(tab: tab.id, host: tab.host, problem: problem, keepsScreen: tab.frame != nil)
    }.first
  }

  /// What a reconnect answers: the tab's own problem, or the state it is in.
  func reconnectReport(for id: SessionTab.ID) -> TabProblem? {
    guard let tab = tabs.first(where: { $0.id == id }), tab.canReconnect else { return nil }
    let problem = tab.problem ?? SessionProblem(kind: .lost, reason: "")
    return TabProblem(tab: tab.id, host: tab.host, problem: problem, keepsScreen: tab.frame != nil)
  }

  /// Whether any terminal on a page is down — marked on its chip.
  func isDisconnected(_ page: TerminalWorkspace) -> Bool {
    page.terminalIDs.contains { id in tabs.first { $0.id == id }?.isDisconnected == true }
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
    if let restored = lastByHost[host.id], (tabs.contains { $0.id == restored && $0.host.id == host.id } || visibleIDs.contains(restored)) {
      selected = restored
    } else {
      selected = visibleWorkspaces.last?.focused ?? visibleExtensions.last?.id
    }
  }

  func select(_ requested: UUID) {
    let id = workspaces.first(where: { $0.id == requested })?.focused ?? requested
    guard tabs.contains(where: { $0.id == id }) || extensions.contains(where: { $0.id == id }) else { return }
    if let index = workspaces.firstIndex(where: { $0.terminalIDs.contains(id) }) {
      if let layout = workspaces[index].layout, !layout.ids.contains(id) {
        workspaces[index].layout = layout.replacing(workspaces[index].focused, with: .tab(id))
      }
      workspaces[index].focused = id
    }
    selected = id
    if let tab = tabs.first(where: { $0.id == id }) {
      currentHost = tab.host
      lastByHost[tab.host.id] = id
    } else if let host = currentHost {
      lastByHost[host.id] = id
    }
    tabMenu = nil
    if let accessory, accessory.tab != id { self.accessory = nil }
    persistHistory()
  }

  /// First click on another tab selects it; click the active tab to open its menu.
  func handleTabClick(_ id: UUID) {
    if selectedWorkspaceID == id || selected == id {
      if let tab = current {
        if let picker = accessories.first(where: { $0.accessory.placement == .popover }),
          tab.canOpen(picker.id)
        {
          toggleAccessory(picker.id, on: tab.id)
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

  /// Closes this plugin's accessory wherever the host drew it: the popover,
  /// or the inspector column when that is what the button opened.
  func dismissAccessory(_ pluginID: String, on id: UUID) {
    if accessory?.tab == id { accessory = nil }
    #if os(macOS)
      if inspectorPlugin == pluginID, current?.id == id {
        inspector = false
        inspectorPlugin = nil
      }
    #endif
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
    extensions.removeAll()
    selected = nil
    currentHost = nil
    lastByHost = [:]
    workspaces = []
    closingWorkspace = nil
    renamingWorkspace = nil
    recents = []
    persistHistory()
    tabMenu = nil
    accessory = nil
    sheet = nil
    pendingClose = nil
  }

  /// What an iCloud account change takes with it: everything `closeAll`
  /// does, except the shells on this machine. Those need nothing from any
  /// account's library — and launch opens one before iCloud has answered,
  /// so the first sign-in would otherwise close the terminal it was typed in.
  func closeAccountSessions() {
    let kept = workspaces.filter { $0.host.isLocal }
    let keptIDs = Set(kept.flatMap(\.terminalIDs))
    let keptTabs = tabs.filter { keptIDs.contains($0.id) }
    guard !keptTabs.isEmpty else {
      closeAll()
      return
    }
    let focus = selected.flatMap { keptIDs.contains($0) ? $0 : nil } ?? kept.last?.focused
    tabs.removeAll { keptIDs.contains($0.id) }
    closeAll()
    tabs = keptTabs
    workspaces = kept
    currentHost = .local
    selected = focus
    if let focus { lastByHost[Host.local.id] = focus }
    persistHistory()
  }

  /// Everything a plugin has open, closed before it is turned off.
  func closePlugin(_ pluginID: String) {
    for entry in extensions.filter({ $0.pluginID == pluginID }) { close(entry.id) }
    if accessory?.plugin == pluginID { accessory = nil }
    if inspectorPlugin == pluginID { inspectorPlugin = nil }
    if sheet?.plugin == pluginID { sheet = nil }
    for tab in tabs { tab.detach(pluginID) }
  }

  func cycleTerminal(forward: Bool) {
    let ids = currentWorkspace?.terminalIDs ?? []
    guard !ids.isEmpty else { return }
    let index = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
    select(ids[(index + (forward ? 1 : ids.count - 1)) % ids.count])
  }

  func requestCloseWorkspace(_ id: UUID) {
    guard let page = workspaces.first(where: { $0.id == id }),
      pendingClose == nil, checkingClose != id else { return }
    closeCheck?.cancel()
    closingWorkspace = id
    workspaceCloseNotes = []
    checkingClose = id
    let inspect = inspectActivity
    closeCheck = Task { [weak self] in
      guard let self else { return }
      for terminalID in page.terminalIDs {
        guard let tab = self.tabs.first(where: { $0.id == terminalID }) else { continue }
        let activity = tab.isLive ? await inspect(tab) : .idle
        guard !Task.isCancelled, self.checkingClose == id else { return }
        if tab.isLive, let message = activity.closeMessage {
          self.workspaceCloseNotes.append("\(self.displayTitle(for: tab.id)): \(message)")
        }
        for attachment in tab.attachments where attachment.attachment.requiresCloseConfirmation {
          self.workspaceCloseNotes.append(attachment.attachment.closeNote ?? "\(self.displayTitle(for: tab.id)) has active plugin work.")
        }
      }
      guard !Task.isCancelled, self.workspaces.contains(where: { $0.id == id }) else { return }
      self.checkingClose = nil
      self.closeCheck = nil
      if self.workspaceCloseNotes.isEmpty {
        self.closeWorkspace(id)
        self.closingWorkspace = nil
      } else { self.pendingClose = id }
    }
  }

  func cancelClose() {
    closeCheck?.cancel()
    closeCheck = nil
    checkingClose = nil
    pendingClose = nil
    closingWorkspace = nil
    workspaceCloseNotes = []
  }

  func closeWorkspace(_ id: UUID) {
    guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
    let page = workspaces[index]
    if checkingClose == id { cancelClose() }
    if renamingWorkspace == id { renamingWorkspace = nil }
    if let record = snapshot(page, index: index) {
      closedTabs.append(record)
      if closedTabs.count > Self.closedTabLimit { closedTabs.removeFirst() }
    }
    // Save the aggregate before any member closes, so retained scrollback survives cleanup.
    for terminal in page.terminalIDs { close(terminal, remember: false) }
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
    closingWorkspace = nil
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
    if let page = closingWorkspace, let workspace = workspaces.first(where: { $0.id == page }) { return "Close \(workspace.name)?" }
    let name = displayTitle(for: id)
    guard !name.isEmpty else { return "Close?" }
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

  /// ⌘W with nothing in the window left to close keeps its usual Mac
  /// meaning: the window. What that does to it is the window's business.
  func requestWindowClose() {
    windowCloseRequests += 1
  }

  /// ⌘W: whatever is open over the window first, then the terminal in
  /// front — its tab too, when it was the only one there — and with nothing
  /// left, the window.
  func requestCloseFocused() {
    if dismissOverlay() { return }
    if let selected { requestClose(selected) } else if closesWindow { requestWindowClose() }
  }

  /// ⌥⌘W: every terminal on the page, after the same check a page close
  /// always makes.
  func requestCloseSelected() {
    if dismissOverlay() { return }
    guard let selected else { return }
    if let page = currentWorkspace { requestCloseWorkspace(page.id) } else { requestClose(selected) }
  }

  /// Closes the topmost thing open over the window, if any.
  private func dismissOverlay() -> Bool {
    if palette != nil {
      palette = nil
    } else if hostPicker {
      hostPicker = false
    } else if accessory != nil {
      accessory = nil
    } else if tabMenu != nil {
      tabMenu = nil
    } else {
      return false
    }
    return true
  }

  func confirmClose() {
    guard let id = pendingClose else { return }
    pendingClose = nil
    if let page = closingWorkspace { closeWorkspace(page); closingWorkspace = nil }
    else { close(id) }
  }

  func close(_ id: SessionTab.ID, remember: Bool = true) {
    if let page = workspace(containing: id), checkingClose == page.id { cancelClose() }
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
      if selected == id { selected = visibleWorkspaces.last?.focused ?? visibleExtensions.last?.id }
      noteIfEmpty()
      return
    }
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let hostID = tabs[index].host.id
    if remember {
      closedTabs.append(ClosedTerminal(tabs[index], index: index))
      if closedTabs.count > Self.closedTabLimit,
        let oldest = closedTabs.firstIndex(where: { $0.id != restoringTab }) {
        closedTabs.remove(at: oldest)
      }
    }
    removeSplitTab(id)
    tabs[index].close()
    if let error = tabs[index].history?.error { reportHistoryProblem(error) }
    tabs.remove(at: index)
    persistHistory()

    // Stay on this host even when the last tab closes. Jumping to another
    // machine is a choice, not a side effect of tidying.
    if selected == id {
      let remaining = workspaces.filter { $0.host.id == hostID }.map(\.focused)
        + extensions.filter { $0.hostID == hostID || $0.hostID == nil }.map(\.id)
      if let next = remaining.last { select(next) } else { selected = nil }
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
    let current = selectedWorkspaceID.flatMap { ids.firstIndex(of: $0) } ?? 0
    let next = forward ? (current + 1) % ids.count : (current - 1 + ids.count) % ids.count
    select(ids[next])
  }

  /// An empty terminal name clears the pin. An empty workspace name keeps the old one.
  func rename(_ id: UUID, to name: String) {
    if renaming == id { renaming = nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let index = workspaces.firstIndex(where: { $0.id == id }) {
      renamingWorkspace = nil
      if !trimmed.isEmpty { workspaces[index].name = trimmed; persistHistory() }
      return
    }
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    // An empty name drops the pin and the chip follows the session, command or directory again.
    tab.pinnedName = trimmed.isEmpty ? nil : trimmed
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
    return tab.isLive ? "" : tab.stateName
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

  /// What a page's chip says beside its name: what stands in for its
  /// focused shell — the session a plugin attached it to. Not the host: the
  /// strip only ever shows the host bar's own host, so naming it on every
  /// chip would say the same word twice. Names are facts, not copy.
  func caption(for page: TerminalWorkspace) -> String {
    tabs.first { $0.id == page.focused }?.subtitle ?? ""
  }

  /// Host picker subtitle: where the host is, and which tab/session is open.
  func workspaceCaption(for host: Host) -> String {
    let owned = tabs.filter { $0.host.id == host.id }
    let preferred = lastByHost[host.id].flatMap { id in owned.first { $0.id == id } }
    let tab = preferred ?? owned.last
    let place = host.isLocal ? "Local machine" : host.address
    guard let tab else { return place }
    let title = displayTitle(for: tab.id)
    if tab.shown != nil {
      return "\(place) · \(title) / \(tab.subtitle)"
    }
    return "\(place) · \(title)"
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
