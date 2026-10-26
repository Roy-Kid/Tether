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

  /// A page rebuilt from a handoff. No history id: the sender's scrollback
  /// stays where it was recorded.
  init(id: UUID, host: Host, name: String, pinnedName: String?, directory: String?, index: Int, attachments: [Attachment]) {
    self.id = id
    self.historyID = nil
    self.host = host
    self.name = name
    self.pinnedName = pinnedName
    self.directory = directory
    self.index = index
    self.attachments = attachments
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
    if handoffPages.first?.id == id { return handoffPages.first }
    return closedTabs.first { $0.id == id }
  }

  func cancelRestore(_ id: UUID) {
    if handoffPages.first?.id == id {
      handoffPages.removeFirst()
      advanceHandoff()
      return
    }
    if restoringTab == id { restoringTab = nil }
    if restoringTab == nil, !handoffPages.isEmpty { advanceHandoff() }
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
    let handoff = handoffPages.first?.id == id
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
    if handoff {
      for restored in mapping.values {
        tabs.first { $0.id == restored }?.handoff = true
      }
      for member in record.members {
        guard let restored = mapping[member.id] else { continue }
        for attachment in member.attachments {
          handoffRestores.append(HandoffRestore(tab: restored, pluginID: attachment.pluginID, state: attachment.state))
        }
      }
      if let focus = handoffFocusID, record.members.contains(where: { $0.id == focus }) {
        pendingHandoffSelection = mapping[focus]
      }
      if handoffPages.first?.id == id { handoffPages.removeFirst() }
    } else {
      closedTabs.removeAll { $0.id == id }
    }
    advanceHandoff()
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
    if let restoringTab, handoffPages.first?.id != restoringTab,
      !closedTabs.contains(where: { $0.id == restoringTab }) {
      cancelRestore(restoringTab)
    }
  }

  /// The open workspaces, as another of this person's devices can reopen them.
  /// Nil when nothing is open. The selected page is the one holding the
  /// terminal in front, not a name: names collide.
  func captureHandoff() -> HandoffSnapshot? {
    var records: [ClosedTerminal] = []
    var selectedIndex = 0
    for (index, workspace) in workspaces.enumerated() {
      guard let record = snapshot(workspace, index: index) else { continue }
      if let selected, workspace.terminalIDs.contains(selected) { selectedIndex = records.count }
      records.append(record)
    }
    guard !records.isEmpty else { return nil }
    return HandoffSnapshot(records: records, selected: selectedIndex)
  }

  /// Queue the pages this device can dial. An unknown host is skipped, and
  /// so is this machine when `allowLocal` is false — a phone has no local shell.
  /// Returns false when nothing was queued, so a saved snapshot is kept until
  /// the library can answer it.
  @discardableResult
  func prepareHandoff(_ snapshot: HandoffSnapshot, hosts: [Host],
    allowLocal: Bool = TerminalSession.isLocalAvailable) -> Bool {
    let chosen = snapshot.pages.indices.contains(snapshot.selected) ? snapshot.selected : nil
    var focus: UUID?
    var pages: [ClosedTerminal] = []
    for (index, page) in snapshot.pages.enumerated() {
      guard let host = hosts.first(where: { $0.id == page.hostID }) else { continue }
      if host.isLocal && !allowLocal { continue }
      guard let record = page.record(host: host) else { continue }
      if index == chosen { focus = page.focused }
      pages.append(record)
    }
    guard !pages.isEmpty else { return false }
    if handoffFocusID == nil { handoffFocusID = focus }
    let begin = handoffPages.isEmpty && restoringTab == nil
    handoffPages.append(contentsOf: pages)
    if begin, let first = handoffPages.first {
      restoringTab = first.id
      intent = .restoreTab(first.id)
    }
    return true
  }

  /// What a test uses instead of the window: prepare, then finish each page
  /// without dialling. The window's own path is `prepareHandoff` and the
  /// password question it already asks.
  func acceptHandoff(_ snapshot: HandoffSnapshot, hosts: [Host],
    allowLocal: Bool = TerminalSession.isLocalAvailable) -> Bool {
    guard prepareHandoff(snapshot, hosts: hosts, allowLocal: allowLocal) else { return false }
    for _ in 0..<20 {
      guard let id = restoringTab, let record = restoration(for: id) else { break }
      let tab = SessionTab(preview: record.host, known: known, name: record.name, live: false)
      guard completeRestore(id, with: tab, makeTerminal: { member in
        SessionTab(preview: member.host, known: self.known, name: member.name, live: false)
      }) else { continue }
    }
    return restoringTab == nil && !tabs.isEmpty
  }

  /// A workspace another device can dial: not this machine, and not empty.
  var hasTransferableWorkspace: Bool {
    workspaces.contains { !$0.host.isLocal && !$0.terminalIDs.isEmpty }
  }

  private func advanceHandoff() {
    if let next = handoffPages.first {
      restoringTab = next.id
      intent = .restoreTab(next.id)
      return
    }
    let pending = pendingHandoffSelection
    pendingHandoffSelection = nil
    handoffFocusID = nil
    restoringTab = nil
    if let pending { select(pending) }
  }
}
