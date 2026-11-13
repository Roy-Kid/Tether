import Foundation
import Tether
import TetherPluginKit
import TetherUI

extension WorkspaceInteraction {
  func execute(_ intent: WorkspaceIntent) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    switch intent {
    case .splitTerminal(let id, let direction): splitTerminal(id, direction: direction)
    case .restoreTab(let id): restoreTab(id)
    case .addTerminal(let id):
      if let page = tabs.workspaces.first(where: { $0.id == id }) { open(page.host, in: id) }
    case .newTerminal:
      if let page = tabs.currentWorkspace { open(page.host, in: page.id) }
      else if TerminalSession.isLocalAvailable { open(.local) }
      else { tabs.hostPicker = true }
    case .newTab:
      if let host = tabs.currentHost { open(host) }
      else if TerminalSession.isLocalAvailable { open(.local) }
      else { tabs.hostPicker = true }
    case .connect(let host): open(host)
    case .reconnect(let id): if let report = tabs.reconnectReport(for: id) { retry(report) }
    case .takeOver: runOperation { [self] _ in await offerTakeOver() }
    case .switchHost(let index):
      guard store.listed.indices.contains(index) else { return }
      if let next = tabs.reveal(store.listed[index]) { execute(next) }
    case .edit(let host):
      _ = performOnWorkspace {
        self.tabs.hostPicker = false
        SettingsRoute.shared.show(self.store.hosts.contains { $0.id == host.id } ? .edit(host.id) : .newHost)
      }
    case .launchPlugin(let id):
      if let plugin = registry.plugins.first(where: { $0.metadata.id == id }), registry.isEnabled(id) {
        launch(plugin)
      }
    case .openPath:
      #if os(macOS)
      let directory = tabs.current?.workingDirectory
      runOperation { [self] _ in await OpenPath.ask(workingDirectory: directory, interaction: self) }
      #endif
    }
  }

  func open(_ host: Host, in workspaceID: UUID? = nil) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    if host.isLocal { tabs.open(host, password: "", in: workspaceID); return }
    runOperation { [self] _ in await openRemote(host, in: workspaceID) }
  }

  func splitTerminal(_ id: UUID, direction: SplitDirection) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    guard let source = tabs.tabs.first(where: { $0.id == id }) else { return }
    if source.host.isLocal { tabs.splitTerminal(id, direction: direction); return }
    runOperation { [self] generation in
      do {
        let connection = try await source.connectionReady()
        guard workIsCurrent(generation), tabs.tabs.contains(where: { $0.id == id }),
          tabs.currentHost?.id == source.host.id else { return }
        tabs.splitTerminal(id, direction: direction, on: connection)
      } catch {
        guard workIsCurrent(generation) else { return }
        notice = WorkspaceNotice(title: "Could Not Split Terminal", message: error.localizedDescription)
      }
    }
  }

  func openRemote(_ host: Host, in workspaceID: UUID? = nil) async {
    let generation = lifecycleGeneration
    guard workIsCurrent(generation) else { return }
    if let issue = host.connectionProblem {
      notice = WorkspaceNotice(title: "Could Not Connect", message: issue)
      return
    }
    let connection = try? await tabs.lease(for: host)
    guard workIsCurrent(generation) else { return }
    if let connection {
      tabs.open(host, on: connection, in: workspaceID)
      return
    }
    let source = await passwordSource(for: host)
    guard workIsCurrent(generation) else { return }
    switch source {
    case .none: tabs.open(host, password: "", in: workspaceID)
    case .saved(let password): tabs.open(host, password: password, in: workspaceID)
    case .ask: ask(ConnectRequest(host: host, workspaceID: workspaceID))
    }
  }

  func offerTakeOver() async {
    let generation = lifecycleGeneration
    guard workIsCurrent(generation) else { return }
    let peers = store.handoff.nearby
    guard !peers.isEmpty, let snapshot = tabs.captureHandoff() else { return }
    if peers.count == 1 { store.handoff.send(snapshot, to: peers[0].id); return }
    let actions = [Dialog.Action.cancel()] + peers.map { peer in
      Dialog.Action(peer.name) { _ in
        guard self.workIsCurrent(generation) else { return }
        self.store.handoff.send(snapshot, to: peer.id)
      }
    }
    _ = await askDialog(Dialog(title: "Take Over", actions: actions))
  }

  func resumeSavedHandoff() {
    guard workIsCurrent(lifecycleGeneration) else { return }
    guard tabs.tabs.isEmpty, tabs.restoringTab == nil else { return }
    let archive = HandoffArchive()
    guard let snapshot = archive.load() else { return }
    if tabs.prepareHandoff(snapshot, hosts: store.listed) { archive.consume() }
  }

  func restoreTab(_ id: UUID) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    guard let record = tabs.restoration(for: id) else { return }
    let host = latest(record.host)
    if host.isLocal { finishRestore(record, tab: tabs.restore(id, host: host, password: "")); return }
    runOperation { [self] generation in
      if let issue = host.connectionProblem {
        tabs.cancelRestore(id)
        notice = WorkspaceNotice(title: "Could Not Connect", message: issue)
        return
      }
      let connection = try? await tabs.lease(for: host)
      guard workIsCurrent(generation) else { return }
      if let connection {
        finishRestore(record, tab: tabs.restore(id, host: host, on: connection))
        return
      }
      let source = await passwordSource(for: host)
      guard workIsCurrent(generation), tabs.restoration(for: id) != nil else { return }
      switch source {
      case .none: finishRestore(record, tab: tabs.restore(id, host: host, password: ""))
      case .saved(let password): finishRestore(record, tab: tabs.restore(id, host: host, password: password))
      case .ask: ask(ConnectRequest(host: host, restoring: id))
      }
    }
  }

  func finishRestore(_ record: ClosedTerminal, tab: SessionTab?) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    guard let tab, let page = tabs.workspace(containing: tab.id) else { return }
    for (saved, id) in zip(record.members, page.terminalIDs) {
      guard !saved.attachments.isEmpty, let terminal = tabs.tabs.first(where: { $0.id == id }) else { continue }
      runOperation { [self, weak terminal] generation in
        guard let terminal, (try? await terminal.connectionReady()) != nil,
          workIsCurrent(generation), tabs.tabs.contains(where: { $0.id == terminal.id }) else { return }
        for attachment in saved.attachments where registry.isEnabled(attachment.pluginID) {
          prepareAttachment(attachment.pluginID, on: terminal)
          terminal.attachment(for: attachment.pluginID)?.restore(from: attachment.state)
        }
      }
    }
  }

  func ask(_ request: ConnectRequest) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    if let tab = request.retrying, connectRequests.contains(where: { $0.retrying == tab }) { return }
    connectRequests.append(request)
    refreshDialogs()
  }

  func latest(_ host: Host) -> Host { store.hosts.first { $0.id == host.id } ?? host }

  enum PasswordSource { case none, saved(String), ask }

  func passwordSource(for host: Host) async -> PasswordSource {
    let generation = lifecycleGeneration
    guard workIsCurrent(generation) else { return .none }
    if host.isLocal { return .none }
    if let password = remembered(for: host), !password.isEmpty { return .saved(password) }
    let master = host.allowsMasterReuse ? await TerminalSession.sshMasterIsRunning(host.sshTarget) : false
    guard workIsCurrent(generation) else { return .none }
    return master || host.offersConfiguredKey ? .none : .ask
  }

  func retry(_ report: TabProblem) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    guard let tab = tabs.tabs.first(where: { $0.id == report.tab }) else { return }
    tab.acknowledge()
    let host = latest(report.host)
    if report.problem.refusedLogin, !host.isLocal { ask(ConnectRequest(host: host, retrying: tab.id)); return }
    runOperation { [self] generation in
      let source = await passwordSource(for: host)
      guard workIsCurrent(generation), tabs.tabs.contains(where: { $0.id == tab.id }), tab.canReconnect else { return }
      if let leader = tabs.reconnectLeader(for: host, besides: tab.id) { tab.follow(leader); return }
      switch source {
      case .none: tab.redial(host: host, password: "", typedNow: false)
      case .saved(let password): tab.redial(host: host, password: password, typedNow: false)
      case .ask: ask(ConnectRequest(host: host, retrying: tab.id))
      }
    }
  }

  func connect(_ request: ConnectRequest, password: String) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    guard connectRequests.contains(where: { $0.id == request.id }) else { return }
    connectRequests.removeAll { $0.id == request.id }
    if let answer = reconnectAnswers.removeValue(forKey: request.id) { answer.resume(returning: password) }
    else if let id = request.restoring {
      guard let record = tabs.restoration(for: id) else { return }
      finishRestore(record, tab: tabs.restore(id, host: latest(request.host), password: password, typedNow: true))
    } else if let id = request.retrying {
      tabs.tabs.first { $0.id == id }?.redial(host: latest(request.host), password: password, typedNow: true)
    } else { tabs.open(latest(request.host), password: password, typedNow: true, in: request.workspaceID) }
  }

  func cancelConnect(_ request: ConnectRequest) {
    guard connectRequests.contains(where: { $0.id == request.id }) else { return }
    connectRequests.removeAll { $0.id == request.id }
    reconnectAnswers.removeValue(forKey: request.id)?.resume(throwing: CancellationError())
    if let id = request.restoring { tabs.cancelRestore(id) }
    if let id = request.retrying { tabs.close(id) }
  }

  func keep(_ offer: TabPasswordOffer) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    keep(offer.offer.password, for: offer.host)
    tabs.answer(offer, kept: true)
  }

  func remembered(for host: Host) -> String? {
    guard host.remembersPassword else { return nil }
    do { return try secrets.password(for: host.passwordID) }
    catch {
      notice = WorkspaceNotice(title: "Could Not Read Password for \(host.displayName)", message: message(for: error))
      return nil
    }
  }

  func keep(_ password: String, for host: Host) {
    guard workIsCurrent(lifecycleGeneration) else { return }
    guard let current = store.hosts.first(where: { $0.id == host.id }) else {
      notice = WorkspaceNotice(title: "Could Not Save Password for \(host.displayName)", message: "This host is no longer in the list.")
      return
    }
    if !store.save(current, password: password) {
      notice = WorkspaceNotice(title: "Could Not Save Password for \(host.displayName)", message: store.problem ?? "")
    }
  }

  func reconnect(host original: Host) async throws -> RemoteConnection {
    let generation = lifecycleGeneration
    guard workIsCurrent(generation) else { throw CancellationError() }
    let host = latest(original)
    let existing = try? await tabs.lease(for: host)
    guard workIsCurrent(generation) else { throw CancellationError() }
    if let existing { return existing }
    let password: String
    let typedNow: Bool
    let source = await passwordSource(for: host)
    guard workIsCurrent(generation) else { throw CancellationError() }
    switch source {
    case .none: (password, typedNow) = ("", false)
    case .saved(let saved): (password, typedNow) = (saved, false)
    case .ask:
      typedNow = true
      let request = ConnectRequest(host: host)
      password = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          guard workIsCurrent(generation) else { continuation.resume(throwing: CancellationError()); return }
          reconnectAnswers[request.id] = continuation
          ask(request)
        }
      } onCancel: {
        Task { @MainActor in
          self.connectRequests.removeAll { $0.id == request.id }
          self.reconnectAnswers.removeValue(forKey: request.id)?.resume(throwing: CancellationError())
        }
      }
    }
    guard workIsCurrent(generation) else { throw CancellationError() }
    let selected = tabs.selected
    tabs.open(host, password: password, typedNow: typedNow)
    guard let tab = tabs.current else { throw CancellationError() }
    let connection = try await withTaskCancellationHandler {
      try await tab.connectionReady()
    } onCancel: { Task { @MainActor in self.tabs.close(tab.id) } }
    guard workIsCurrent(generation) else { throw CancellationError() }
    tabs.selected = selected
    return connection
  }
}
