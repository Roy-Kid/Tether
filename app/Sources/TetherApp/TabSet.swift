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
  var extensions: [WorkspaceEntry] = []
  var selected: SessionTab.ID?
  var currentHost: Host?
  var zen = false
  var tabBarVisible = true
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
  var pendingClose: SessionTab.ID?
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
    visibleTabs.map(\.id) + visibleExtensions.map(\.id)
  }

  var recentHostIDs: [UUID] { recents }

  var showsTabBar: Bool { tabBarVisible && !zen }

  func open(_ host: Host, password: String, typedNow: Bool = false) {
    show(host)
    adopt(SessionTab(host: host, password: password, typedNow: typedNow, known: known, name: nextName(for: host)))
  }

  /// Opens a new terminal on a connection that is already authenticated.
  func open(_ host: Host, on connection: RemoteConnection) {
    show(host)
    adopt(SessionTab(host: host, connection: connection, known: known, name: nextName(for: host)))
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

  func adopt(_ tab: SessionTab) {
    show(tab.host)
    tab.offersToSave = !keepDeclined.contains(tab.host.id)
    // A person who declined a question the login asked has closed it.
    let id = tab.id
    tab.onDeclined = { [weak self] in self?.close(id) }
    tabs.append(tab)
    select(tab.id)
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
    selected = id
    if let tab = tabs.first(where: { $0.id == id }) {
      currentHost = tab.host
      lastByHost[tab.host.id] = id
    } else if let host = currentHost {
      lastByHost[host.id] = id
    }
    tabMenu = nil
    if let accessory, accessory.tab != id { self.accessory = nil }
  }

  /// First click on another tab selects it; click the active tab to open its menu.
  func handleTabClick(_ id: UUID) {
    if selected == id {
      if let tab = tabs.first(where: { $0.id == id }) {
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

  func closeAll() {
    tabs.forEach { $0.close() }
    extensions.forEach { $0.workspace.close() }
    tabs.removeAll()
    extensions.removeAll()
    selected = nil
    currentHost = nil
    lastByHost = [:]
    recents = []
    tabMenu = nil
    accessory = nil
    sheet = nil
    pendingClose = nil
  }

  /// Everything a plugin has open, closed before it is turned off.
  func closePlugin(_ pluginID: String) {
    for entry in extensions.filter({ $0.pluginID == pluginID }) { close(entry.id) }
    if accessory?.plugin == pluginID { accessory = nil }
    if inspectorPlugin == pluginID { inspectorPlugin = nil }
    if sheet?.plugin == pluginID { sheet = nil }
    for tab in tabs { tab.detach(pluginID) }
  }

  /// Asks before closing anything.
  ///
  /// Every time, not only for a live session: what a tab holds is the
  /// scrollback as much as the connection, closing is not undoable, and on a
  /// phone the button is under a thumb that is already over the screen.
  /// A selector that is open is dismissed first — it is what the gesture
  /// was aimed at.
  func requestClose(_ id: SessionTab.ID) {
    if tabMenu == id {
      tabMenu = nil
      return
    }
    if accessory?.tab == id {
      accessory = nil
      return
    }
    pendingClose = id
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

  /// The one extra line under the question, when a plugin on the tab leaves
  /// something behind.
  var closeNote: String? {
    tabs.first { $0.id == pendingClose }?.attachments.lazy.compactMap(\.attachment.closeNote).first
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
    requestClose(selected)
  }

  func confirmClose() {
    guard let id = pendingClose else { return }
    pendingClose = nil
    close(id)
  }

  func close(_ id: SessionTab.ID) {
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
    let hostID = tabs[index].host.id
    tabs[index].close()
    tabs.remove(at: index)

    // Stay on this host even when the last tab closes. Jumping to another
    // machine is a choice, not a side effect of tidying.
    if selected == id {
      let remaining = tabs.filter { $0.host.id == hostID }.map(\.id)
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
    tab.name = trimmed
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
