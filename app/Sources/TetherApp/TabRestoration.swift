import Foundation
import Tether

/// Reopening information and a reference to separately stored terminal content.
struct ClosedTerminal: Identifiable, Equatable, Codable {
  struct Attachment: Equatable, Codable {
    let pluginID: String
    let state: Data
  }

  let id: UUID
  let historyID: UUID?
  let host: Host
  let name: String
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

  @MainActor
  init(_ tab: SessionTab, index: Int) {
    id = tab.id
    historyID = tab.historyID
    host = tab.host
    name = tab.name
    directory = tab.workingDirectory
    self.index = index
    attachments = tab.attachments.compactMap { entry in
      entry.attachment.restorationState.map { Attachment(pluginID: entry.pluginID, state: $0) }
    }
  }
  @MainActor
  init(workspace: TerminalWorkspace, root: SessionTab, panes: [SessionTab], index: Int) {
    self.init(root, index: index)
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
  func completeRestore(_ id: UUID, with tab: SessionTab) -> Bool {
    guard let record = restoration(for: id), tab.host.sameSessionTarget(as: record.host)
    else {
      tab.close()
      cancelRestore(id)
      return false
    }
    tab.historyID = record.historyID
    closedTabs.removeAll { $0.id == id }
    restoringTab = nil
    adopt(tab, at: record.index)
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
