import Foundation
import Tether

/// Reopening information and a reference to separately stored terminal content.
struct ClosedTerminal: Identifiable, Equatable, Codable {
  struct Attachment: Equatable, Codable {
    let pluginID: String
    let state: Data
  }

  var id: UUID
  let historyID: UUID?
  let host: Host
  var name: String
  let directory: String?
  let index: Int
  let attachments: [Attachment]
  var layout: TerminalLayout?
  var panes: [ClosedTerminal]?
  var focusedPane: UUID?
  var groupHost: Host?
  var parentID: UUID?
  var neighbor: UUID?
  var splitVertical: Bool?
  var splitBefore: Bool?
  var splitRatio: Double?
  var neighborPanes: [UUID]?

  @MainActor
  init(_ tab: SessionTab, index: Int) {
    id = tab.id
    historyID = tab.historyID
    host = tab.host
    name = tab.name
    directory = tab.workingDirectory
    self.index = index
    var states = tab.pendingAttachments
    for entry in tab.attachments {
      if let state = entry.attachment.restorationState { states[entry.pluginID] = state }
    }
    attachments = states.sorted { $0.key < $1.key }.map { Attachment(pluginID: $0.key, state: $0.value) }
  }
  @MainActor
  init(workspace: TerminalWorkspace, root: SessionTab, panes: [SessionTab], index: Int) {
    self.init(root, index: index)
    id = workspace.id
    name = workspace.name
    layout = workspace.layout
    self.panes = panes.map { ClosedTerminal($0, index: index) }
    focusedPane = workspace.focused
    groupHost = workspace.host
  }

}

extension TabSet {
  var canRestoreTab: Bool { !closedTabs.isEmpty && restoringTab == nil && intent == nil }

  func requestRestoreTab() {
    guard canRestoreTab, let last = closedTabs.last else { return }
    restoringTab = last.id
    intent = .restoreTab(last.id)
  }

  func restoration(for id: UUID) -> ClosedTerminal? {
    guard restoringTab == id else { return nil }
    return closedTabs.first { $0.id == id }
  }

  func cancelRestore(_ id: UUID) {
    if restoringTab == id { restoringTab = nil }
  }

  /// Consume history once the replacement tab is ready to begin connecting.
  @discardableResult
  func commitRestoration(_ record: ClosedTerminal, panes: [SessionTab]) -> Bool {
    let saved = record.panes ?? [record]
    guard restoringTab == record.id, panes.count == saved.count, !panes.isEmpty,
      zip(saved, panes).allSatisfy({ $0.1.host.sameSessionTarget(as: $0.0.host) }) else { return false }
    var ids: [UUID: UUID] = [:]
    suppressPersistence = true
    let roots = visibleWorkspaceRoots
    let insertion = record.index < roots.count && record.index >= 0
      ? (tabs.firstIndex(where: { $0.id == roots[record.index].id }) ?? tabs.count) : tabs.count
    for (offset, pair) in zip(saved, panes).enumerated() {
      let (old, pane) = pair
      pane.historyID = old.historyID
      pane.pendingAttachments = Dictionary(old.attachments.map { ($0.pluginID, $0.state) }, uniquingKeysWith: { _, latest in latest })
      ids[old.id] = pane.id
      adopt(pane, at: insertion + offset)
    }
    let root = panes[0]
    #if os(macOS)
      if let parent = terminalWorkspaces.first(where: { $0.value.id == record.parentID }) {
        terminalWorkspaces.removeValue(forKey: root.id)
        var neighbors = Set(record.neighborPanes ?? [record.neighbor ?? parent.value.focused])
          .intersection(parent.value.layout.leaves)
        if neighbors.isEmpty { neighbors.insert(parent.value.focused) }
        parent.value.layout = parent.value.layout.restoring(root.id, beside: neighbors,
          vertical: record.splitVertical ?? false, before: record.splitBefore ?? false, ratio: record.splitRatio ?? 0.5)
        parent.value.focused = root.id
        select(parent.key)
      } else {
        let workspace = TerminalWorkspace(root, host: record.groupHost, id: record.id)
        workspace.name = record.name
        workspace.layout = (record.layout ?? .pane(record.id)).remapping(ids)
        workspace.focused = ids[record.focusedPane ?? record.id] ?? root.id
        for pane in panes { terminalWorkspaces.removeValue(forKey: pane.id) }
        terminalWorkspaces[root.id] = workspace
        select(root.id)
      }
    #endif
    closedTabs.removeAll { $0.id == record.id }
    restoringTab = nil
    suppressPersistence = false
    persistHistory()
    return true
  }

  @discardableResult
  func completeRestore(_ id: UUID, with tab: SessionTab) -> Bool {
    guard let record = restoration(for: id), commitRestoration(record, panes: [tab]) else {
      tab.close()
      cancelRestore(id)
      return false
    }
    return true
  }

  func restore(_ id: UUID, host: Host, password: String, typedNow: Bool = false) -> SessionTab? {
    guard let record = restoration(for: id) else { return nil }
    let tab = SessionTab(host: host, password: password, typedNow: typedNow, known: known,
      name: record.name, directory: record.directory)
    return completeRestore(id, with: tab) ? tab : nil
  }

  func restore(_ id: UUID, host: Host, on connection: RemoteConnection) -> SessionTab? {
    guard let record = restoration(for: id) else { return nil }
    let tab = SessionTab(host: host, connection: connection, known: known, name: record.name)
    return completeRestore(id, with: tab) ? tab : nil
  }

  /// Deleted hosts or changed security policies must not return through history.
  func reconcileClosedTabs(with hosts: [Host]) {
    closedTabs.removeAll { record in
      (record.panes ?? [record]).contains { pane in pane.host.isManaged && !hosts.contains { $0.sameSessionTarget(as: pane.host) } }
    }
    persistHistory()
    if let restoringTab, !closedTabs.contains(where: { $0.id == restoringTab }) {
      cancelRestore(restoringTab)
    }
  }
}
