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
  /// A name the person typed. Nil follows the session, command or directory.
  let pinnedName: String?
  let directory: String?
  let index: Int
  let attachments: [Attachment]
  var companions: [ClosedTerminal]?
  var workspaceName: String?
  var layout: WorkspaceSplit?
  var focusedTerminal: UUID?

  var members: [ClosedTerminal] { [self] + (companions ?? []) }
  var historyIDs: [UUID] { members.compactMap(\.historyID) }

  @MainActor
  init(_ tab: SessionTab, index: Int) {
    id = tab.id
    historyID = tab.historyID
    host = tab.host
    name = tab.name
    pinnedName = tab.pinnedName
    directory = tab.workingDirectory
    self.index = index
    attachments = tab.attachments.compactMap { entry in
      entry.attachment.restorationState.map { Attachment(pluginID: entry.pluginID, state: $0) }
    }
  }
}

extension TabSet {
  func snapshot(_ workspace: TerminalWorkspace, index: Int) -> ClosedTerminal? {
    let members = workspace.terminalIDs.compactMap { id in tabs.first { $0.id == id } }
    guard let first = members.first else { return nil }
    var record = ClosedTerminal(first, index: index)
    record.companions = members.dropFirst().enumerated().map { ClosedTerminal($0.element, index: $0.offset + 1) }
    record.workspaceName = workspace.name
    record.layout = workspace.layout
    record.focusedTerminal = workspace.focused
    return record
  }

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
  func completeRestore(_ id: UUID, with tab: SessionTab, makeTerminal: ((ClosedTerminal) -> SessionTab)? = nil) -> Bool {
    guard let record = restoration(for: id), tab.host.sameSessionTarget(as: record.host)
    else {
      tab.close()
      cancelRestore(id)
      return false
    }
    guard record.members.allSatisfy({ tab.host.sameSessionTarget(as: $0.host) }),
      record.companions?.isEmpty != false || makeTerminal != nil else {
      tab.close()
      cancelRestore(id)
      return false
    }
    tab.historyID = record.historyID
    tab.pinnedName = TerminalLabels.restoredPin(name: record.name, pinned: record.pinnedName)
    adopt(tab, at: record.index)
    guard let page = workspace(containing: tab.id) else { cancelRestore(id); return false }
    var mapping = [record.id: tab.id]
    for member in record.companions ?? [] {
      guard let restored = makeTerminal?(member) else { continue }
      restored.historyID = member.historyID
      restored.pinnedName = TerminalLabels.restoredPin(name: member.name, pinned: member.pinnedName)
      adopt(restored, in: page.id)
      mapping[member.id] = restored.id
    }
    if let index = workspaces.firstIndex(where: { $0.id == page.id }) {
      workspaces[index].name = record.workspaceName ?? record.name
      workspaces[index].layout = record.layout?.remapping(mapping)
      workspaces[index].focused = record.focusedTerminal.flatMap { mapping[$0] } ?? tab.id
      select(workspaces[index].focused)
    }
    closedTabs.removeAll { $0.id == id }
    restoringTab = nil
    persistHistory()
    return true
  }

  func restore(_ id: UUID, host: Host, password: String, typedNow: Bool = false) -> SessionTab? {
    guard let record = restoration(for: id) else { return nil }
    let tab = SessionTab(host: host, password: password, typedNow: typedNow, known: known,
      name: record.name, directory: record.directory)
    return completeRestore(id, with: tab, makeTerminal: { member in
      if !host.isLocal, host.allowsConnectionReuse {
        return SessionTab(host: host, waitingFor: tab, known: self.known, name: member.name, directory: member.directory)
      }
      return SessionTab(host: host, password: password, typedNow: typedNow, known: self.known,
        name: member.name, directory: member.directory)
    }) ? tab : nil
  }

  func restore(_ id: UUID, host: Host, on connection: RemoteConnection) -> SessionTab? {
    guard let record = restoration(for: id) else { return nil }
    let tab = SessionTab(host: host, connection: connection, known: known, name: record.name, directory: record.directory)
    return completeRestore(id, with: tab, makeTerminal: { member in
      SessionTab(host: host, connection: connection, known: self.known, name: member.name, directory: member.directory)
    }) ? tab : nil
  }

  /// Deleted hosts or changed security policies must not return through history.
  func reconcileClosedTabs(with hosts: [Host]) {
    closedTabs.removeAll { record in
      record.host.isManaged && !hosts.contains { $0.sameSessionTarget(as: record.host) }
    }
    persistHistory()
    if let restoringTab, !closedTabs.contains(where: { $0.id == restoringTab }) {
      cancelRestore(restoringTab)
    }
  }
}
