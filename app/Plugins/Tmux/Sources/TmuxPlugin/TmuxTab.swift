import SwiftUI
import Tether
import TetherPluginKit
import TetherUI

/// tmux on one terminal tab: the session it is attached to, if any, and
/// whether that session is what the tab is showing.
///
/// The tab's shell is never replaced — choosing "Original shell" shows it
/// again with the tmux attachment still held, so going back to tmux is a
/// switch and not a reattach.
@MainActor @Observable
public final class TmuxTab: TabAttachment {
  public let tab: TabContext
  public var sessions: [TmuxSessionInfo] = []
  public var session: TmuxSessionInfo?
  public var snapshot: TmuxSnapshot?
  public var error: String?
  public var missing = false
  public var busy = false
  public var draftName = ""
  /// Whether the tab wants tmux in front of its shell. What it shows is
  /// `isShowing`, which also needs a session to be there.
  public var showing = false
  public private(set) var connection: RemoteConnection?
  public var pendingDestruction: TmuxAction?
  public var sessionToEnd: TmuxSessionInfo?
  public var windowToEnd: TmuxListedWindow?
  public var renameWindow: TmuxWindowInfo?
  public var renameSession: TmuxSessionInfo?
  public var renameText = ""
  private var workspace: TmuxWorkspace?
  private var pump: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var closed = false
  private let creation = SessionCreation()
  /// The tab, if any, already attached to a session. One control client per
  /// session per window: a second would split tmux's idea of the size.
  private let owner: (String) -> TmuxTab?
  private let onClose: () -> Void
  /// The size this view wants the window to be. Held rather than compared
  /// against the last request: tmux sizes a window for all of its clients
  /// (`window-size`, default `latest`), so another client can change it
  /// underneath us at any time, and asking once is not asking.
  private var wanted: (UInt16, UInt16)?
  private var sizeTask: Task<Void, Never>?

  init(tab: TabContext, owner: @escaping (String) -> TmuxTab?, onClose: @escaping () -> Void) {
    self.tab = tab
    self.connection = tab.plugin.connection
    self.owner = owner
    self.onClose = onClose
  }

  // MARK: - TabAttachment

  public var isShowing: Bool { showing && session != nil }
  public var subtitle: String {
    guard let session else { return "" }
    if let window = currentWindow { return "\(session.name) / \(window.name)" }
    return session.name
  }
  public var isDisconnected: Bool { ended }
  public var closeNote: String? { session == nil ? nil : "tmux stays on the host." }
  public var commands: [PluginCommand] {
    guard session != nil else { return [] }
    let detach = PluginCommand(id: "detach", title: "Detach Session", symbol: "eject") {
      [weak self] in self?.detachSession()
    }
    return [detach] + paneCommands
  }
  public func content() -> AnyView { AnyView(TmuxContent(model: self)) }
  public func inspector() -> AnyView { AnyView(TmuxInspector(model: self)) }
  public func accessoryContent() -> AnyView { AnyView(TmuxPicker(model: self)) }
  public func connectionChanged(_ connection: RemoteConnection) { self.connection = connection }
  public func close() {
    closed = true
    operation?.cancel()
    pump?.cancel()
    sizeTask?.cancel()
    workspace?.detach()
    workspace = nil
    onClose()
  }

  // MARK: - Pointing at a pane's text

  /// What pointing at a pane's text does: whatever the tab's plugins offer,
  /// as in the tab's own shell, with a relative path read from where the
  /// pane is rather than where the tab's shell is.
  public func links(for pane: UInt32) -> TerminalLinks {
    TerminalLinks(
      find: { [weak self] row, column in
        self?.workspace?.link(pane: pane, row: row, column: column)
      },
      actions: { [weak self] link in
        guard let self else { return nil }
        return tab.linkActions(
          PointedLink(link: link, directory: { [weak self] in await self?.directory(of: pane) }))
      })
  }

  /// Where a pane is: what its shell reported, or else what tmux knows.
  func directory(of pane: UInt32) async -> String? {
    if let reported = workspace?.workingDirectory(pane: pane) { return reported }
    guard let connection else { return nil }
    return try? await connection.tmuxPaneDirectory(id: pane)
  }

  // MARK: - State

  public var ended: Bool { snapshot?.ended != nil }
  public var currentWindow: TmuxWindowInfo? {
    snapshot?.windows.first(where: \.active) ?? snapshot?.windows.first
  }
  public var activePane: TmuxPaneFrame? {
    snapshot?.panes.first { $0.window == currentWindow?.id && $0.active }
  }
  /// What can be done to the attached session's panes and windows.
  public var paneCommands: [PluginCommand] {
    guard session != nil, !ended else { return [] }
    var result = [
      PluginCommand(id: "newWindow", title: "New window", symbol: "plus.rectangle") { [weak self] in
        self?.perform(.newWindow)
      }
    ]
    if let pane = activePane {
      result += [
        PluginCommand(
          id: "splitHorizontal", title: "Split left and right", symbol: "rectangle.split.2x1"
        ) { [weak self] in self?.perform(.split(id: pane.id, horizontal: true)) },
        PluginCommand(
          id: "splitVertical", title: "Split top and bottom", symbol: "rectangle.split.1x2"
        ) { [weak self] in self?.perform(.split(id: pane.id, horizontal: false)) },
        PluginCommand(id: "zoom", title: "Zoom pane", symbol: "arrow.up.left.and.arrow.down.right")
        { [weak self] in self?.perform(.zoomPane(id: pane.id)) },
      ]
    }
    return result
  }
  public func windows(for session: TmuxSessionInfo) -> [TmuxListedWindow] {
    if self.session?.id == session.id, let snapshot, !snapshot.windows.isEmpty {
      return snapshot.windows.map { window in
        let listed = session.windows.first { $0.id == window.id }
        return TmuxListedWindow(
          id: window.id,
          index: listed?.index ?? window.id,
          name: window.name,
          active: window.active,
          panes: UInt32(snapshot.panes.filter { $0.window == window.id }.count))
      }
      .sorted { $0.index < $1.index }
    }
    return session.windows
  }

  // MARK: - Choosing

  /// Shows a session on this tab — or, when another tab already has it,
  /// brings that tab forward instead of attaching a second time.
  public func choose(_ chosen: TmuxSessionInfo, windowID: UInt32?) {
    defer { tab.dismissAccessory() }
    if let other = owner(chosen.id), other !== self {
      other.showing = true
      other.tab.focus()
      if let windowID { other.perform(.selectWindow(id: windowID)) }
      return
    }
    showing = true
    if session?.id == chosen.id {
      if let windowID { perform(.selectWindow(id: windowID)) }
    } else {
      open(chosen, windowID: windowID)
    }
  }

  /// The shell this tab was opened with. tmux stays attached behind it.
  public func showShell() {
    showing = false
    tab.dismissAccessory()
  }

  public func detachSession() {
    pump?.cancel()
    workspace?.detach()
    workspace = nil
    session = nil
    snapshot = nil
    showing = false
    sizeTask?.cancel()
  }

  // MARK: - Operations

  public func run(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy, !closed else { return }
    busy = true
    error = nil
    operation = Task { [weak self] in
      do { try await action() } catch is CancellationError {} catch {
        self?.error = error.localizedDescription
      }
      self?.busy = false
    }
  }

  /// The tab's lease. A tab attaches this only once it has one, so its
  /// absence is a tab that has since lost it.
  private func lease() throws -> RemoteConnection {
    guard let connection else { throw TmuxTabError.noConnection }
    return connection
  }

  public func refresh() {
    run { [self] in
      missing = false
      do {
        sessions = try await lease().tmuxSessions()
      } catch {
        let text = error.localizedDescription
        missing =
          text.localizedCaseInsensitiveContains("not found")
          || text.localizedCaseInsensitiveContains("no such file")
          || text.localizedCaseInsensitiveContains("not installed")
        throw error
      }
    }
  }

  /// Reports success only after the new session is attached. The draft and
  /// error remain available to the presenting form when an operation fails.
  public func create(onSuccess: @escaping @MainActor () -> Void) {
    let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    run { [self] in
      let connection = try lease()
      let created = try await creation.perform(
        name: name,
        create: { try await connection.createTmux(name: $0) },
        attach: { try await self.attach($0) })
      guard !closed, !Task.isCancelled else { return }
      if !sessions.contains(where: { $0.id == created.id }) { sessions.append(created) }
      draftName = ""
      showing = true
      onSuccess()
    }
  }

  public func open(_ session: TmuxSessionInfo, windowID: UInt32? = nil) {
    run { [self] in
      try await attach(session)
      if let windowID {
        try await workspace?.perform(.selectWindow(id: windowID))
      }
    }
  }

  public func endSession(_ ending: TmuxSessionInfo) {
    // Whichever tab is showing it, not only this one: a tab left attached
    // to a killed session would show it as a lost connection.
    owner(ending.id)?.detachSession()
    run { [self] in
      let connection = try lease()
      try await connection.endTmux(sessionID: ending.id)
      sessions = try await connection.tmuxSessions()
    }
  }

  /// Through the connection, not the workspace: the window may belong to a
  /// session nobody here is attached to. An attached one hears of it from
  /// tmux like any other client would.
  public func endWindow(_ window: TmuxListedWindow) {
    run { [self] in
      let connection = try lease()
      try await connection.endTmuxWindow(id: window.id)
      sessions = try await connection.tmuxSessions()
    }
  }

  public func renameSession(_ renamed: TmuxSessionInfo, to name: String) {
    run { [self] in
      let connection = try lease()
      try await connection.renameTmux(sessionID: renamed.id, name: name)
      sessions = try await connection.tmuxSessions()
    }
  }

  private func attach(_ session: TmuxSessionInfo) async throws {
    workspace?.detach()
    pump?.cancel()
    let workspace = try await lease().attachTmux(sessionID: session.id)
    guard !closed, !Task.isCancelled else {
      workspace.detach()
      return
    }
    self.workspace = workspace
    self.session = session
    self.snapshot = workspace.snapshot()
    // A fresh control client has no size of its own — tmux gives it the
    // default 80x24 — so the size the view already wants is asserted again
    // the moment there is something to assert it against.
    enforceSize()
    pump = Task { [weak self] in
      while await workspace.awaitChange() {
        guard !Task.isCancelled, let self else { return }
        self.snapshot = workspace.snapshot()
        self.enforceSize()
      }
      if !Task.isCancelled { self?.snapshot = workspace.snapshot() }
    }
  }

  public func reconnect() {
    run { [self] in
      connection = try await tab.plugin.reconnect()
      sessions = try await lease().tmuxSessions()
      if let previous = session, let found = sessions.first(where: { $0.id == previous.id }) {
        try await attach(found)
      } else {
        session = nil
        snapshot = nil
        error = "That session is gone."
      }
    }
  }

  public func perform(_ action: TmuxAction) {
    guard !ended else { return }
    run { [self] in try await workspace?.perform(action) }
  }

  func send(_ pane: UInt32, _ input: TerminalInput) {
    guard !ended else { return }
    do { try workspace?.send(pane: pane, input: input) } catch {
      self.error = error.localizedDescription
    }
  }

  func resize(_ columns: UInt16, _ rows: UInt16) {
    guard columns > 0, rows > 0 else { return }
    wanted = (columns, rows)
    enforceSize()
  }

  /// Asks tmux for the size this view wants, unless the window already has
  /// it.
  ///
  /// Called again on every snapshot, because the window's size is a fact
  /// tmux reports rather than one we hold: a second client attaching, or
  /// becoming the latest one, resizes the window under us, and the view
  /// would go on drawing the top-left corner of a grid it never asked for.
  private func enforceSize() {
    guard !ended, !closed, let workspace, let wanted else { return }
    guard let window = currentWindow else { return }
    guard window.width != wanted.0 || window.height != wanted.1 else {
      sizeTask?.cancel()
      return
    }
    sizeTask?.cancel()
    sizeTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(100))
        try await workspace.perform(.resize(columns: wanted.0, rows: wanted.1))
      } catch is CancellationError {} catch { self?.error = error.localizedDescription }
    }
  }
}

enum TmuxTabError: LocalizedError {
  case noConnection
  var errorDescription: String? { "Not connected." }
}
