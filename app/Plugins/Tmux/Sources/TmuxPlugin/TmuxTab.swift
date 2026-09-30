import SwiftUI
import Tether
import TetherPluginKit
import TetherUI

/// tmux on one terminal tab: the session it is attached to, if any, and
/// whether that session is what the tab is showing.
///
/// The tab's shell is never replaced — choosing its shell shows it again
/// while keeping the tmux session attached, so switching back is immediate.
@MainActor @Observable
public final class TmuxTab: TabAttachment {
  public let tab: TabContext
  public var sessions: [TmuxSessionInfo] = []
  /// The session a tmux client on this tab's own shell tty is showing.
  public var shellSessionID: String?
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
  /// The name being edited, while the rename dialog is open.
  public var renaming: TmuxRename?
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
  /// Notches from the wheel that have not been applied yet. One drainer
  /// owns them: a task per notch finished out of order, and an earlier
  /// snapshot then painted over a later one, so the wheel appeared to do
  /// nothing.
  private var scrollSteps = ScrollSteps()
  private var scrollTask: Task<Void, Never>?

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
    // This session is already being rendered by the shell's tmux client on
    // this tab. Keep that client as the one visible representation instead
    // of attaching a second control-mode client to the same session.
    if shellSessionID == chosen.id {
      detachSession()
      tab.dismissAccessory()
      return
    }
    if let other = owner(chosen.id), other !== self {
      other.showing = true
      other.tab.focus()
      if let windowID { other.perform(.selectWindow(id: windowID)) }
      tab.dismissAccessory()
      return
    }
    // The shell may already be this session, and its tty is learned after
    // connect. Covering it before that is known replaces the client: the
    // status line is not in the pane, and prefix+s never reaches tmux, so
    // the overlay tmux would have drawn does not appear.
    if connection != nil, shellSessionID == nil {
      tab.dismissAccessory()
      Task { [weak self] in
        guard let self else { return }
        if self.tab.terminalName() == nil { self.showing = false }
        switch await self.shellClient(of: chosen.id) {
        case .thisSession:
          self.detachSession()
        case .other:
          guard !self.closed else { return }
          self.cover(chosen, windowID: windowID)
        case .unknown:
          // A control client left attached keeps asking for its own size,
          // and the shell's tmux window follows it.
          self.detachSession()
        }
      }
      return
    }
    cover(chosen, windowID: windowID)
  }

  /// Puts `chosen` in front of the shell. The shell's own client never
  /// reaches here: that one stays the shell.
  private func cover(_ chosen: TmuxSessionInfo, windowID: UInt32?) {
    if session?.id == chosen.id {
      showing = true
      if let windowID { perform(.selectWindow(id: windowID)) }
      tab.dismissAccessory()
    } else {
      open(chosen, windowID: windowID) { [weak self] in
        guard let self else { return }
        self.showing = true
        self.tab.dismissAccessory()
      }
    }
  }

  /// What this tab's shell is doing with `id`. A remote tty does not exist
  /// at connect, so this waits briefly. Unknown stays unknown: covering the
  /// shell then is what took its place.
  private enum ShellClient {
    case thisSession
    case other
    case unknown
  }

  private func shellClient(of id: String) async -> ShellClient {
    if shellSessionID == id { return .thisSession }
    guard let connection else { return .other }
    for _ in 0..<10 {
      if closed || Task.isCancelled { return .unknown }
      if let tty = tab.terminalName() {
        do {
          let found = try await connection.tmuxSession(forClientTTY: tty)
          if closed || Task.isCancelled { return .unknown }
          if let found {
            shellSessionID = found
            return found == id ? .thisSession : .other
          }
          return .other
        } catch {
          try? await Task.sleep(for: .milliseconds(200))
          continue
        }
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return .unknown
  }

  /// Show the shell this tab was opened with, keeping tmux attached.
  public func showShell() {
    if let session, shellSessionID == session.id {
      detachSession()
    } else {
      showing = false
    }
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
        let connection = try lease()
        sessions = try await connection.tmuxSessions()
        if let tty = tab.terminalName() {
          shellSessionID = try? await connection.tmuxSession(forClientTTY: tty)
        } else {
          shellSessionID = nil
        }
        // This shell is already the client. The pane view would be a second
        // one, and prefix would type into the program inside the pane.
        uncoverShellClient()
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
    let directory = tab.workingDirectory()
    run { [self] in
      let connection = try lease()
      let created = try await creation.perform(
        name: name,
        create: { try await connection.createTmux(name: $0, directory: directory) },
        attach: { try await self.attach($0) })
      guard !closed, !Task.isCancelled else { return }
      if !sessions.contains(where: { $0.id == created.id }) { sessions.append(created) }
      draftName = ""
      showing = true
      onSuccess()
    }
  }

  public func open(
    _ session: TmuxSessionInfo, windowID: UInt32? = nil,
    onSuccess: @escaping @MainActor () -> Void = {}
  ) {
    run { [self] in
      try await attach(session)
      if let windowID {
        try await workspace?.perform(.selectWindow(id: windowID))
      }
      guard !closed, !Task.isCancelled else { return }
      onSuccess()
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

  public func rename(_ renamed: TmuxRename, to name: String) {
    switch renamed {
    case .session(let session): renameSession(session, to: name)
    case .window(let window): perform(.renameWindow(id: window.id, name: name))
    }
  }

  public func renameSession(_ renamed: TmuxSessionInfo, to name: String) {
    run { [self] in
      let connection = try lease()
      try await connection.renameTmux(sessionID: renamed.id, name: name)
      sessions = try await connection.tmuxSessions()
    }
  }

  /// Drops the control client when this tab's shell is already showing the
  /// session. One client draws it; the other was covering it.
  func uncoverShellClient() {
    guard let shellSessionID, session?.id == shellSessionID else { return }
    detachSession()
  }

  /// Waits briefly for the shell's tty, which a remote session learns after
  /// connect, and gets out of the way if that shell is this session.
  func followShellClient() async {
    guard connection != nil else { return }
    let watched = session?.id
    for _ in 0..<40 {
      if Task.isCancelled || !showing || session?.id != watched { return }
      if let tty = tab.terminalName(), let connection {
        let id = try? await connection.tmuxSession(forClientTTY: tty)
        if Task.isCancelled || !showing || session?.id != watched { return }
        shellSessionID = id
        if id == watched {
          uncoverShellClient()
          return
        }
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  private func attach(_ session: TmuxSessionInfo) async throws {
    let connection = try lease()
    let workspace = try await connection.attachTmux(sessionID: session.id)
    guard !closed, !Task.isCancelled else {
      workspace.detach()
      return
    }
    pump?.cancel()
    self.workspace?.detach()
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

  func scroll(_ pane: UInt32, lines: Int32) {
    guard !ended, workspace != nil else { return }
    scrollSteps.add(pane: pane, lines: lines)
    guard scrollTask == nil else { return }
    scrollTask = Task { [weak self] in
      await self?.drainScroll()
    }
  }

  private func drainScroll() async {
    defer { scrollTask = nil }
    guard let workspace else { return }
    while !scrollSteps.values.isEmpty {
      let batch = scrollSteps.values
      scrollSteps = ScrollSteps()
      do {
        for step in batch {
          try await workspace.scroll(pane: step.pane, lines: step.lines)
        }
        guard !ended else { return }
        snapshot = workspace.snapshot()
      } catch {
        scrollSteps = ScrollSteps()
        self.error = error.localizedDescription
        return
      }
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

/// Wheel notches waiting to be applied, with a run of the same pane added
/// together. Opposite notches that cancel are dropped, so a swipe that
/// comes back to where it started does not scroll and then undo itself
/// after the fact.
struct ScrollSteps: Equatable {
  struct Step: Equatable {
    var pane: UInt32
    var lines: Int32
  }

  private(set) var values: [Step] = []

  mutating func add(pane: UInt32, lines: Int32) {
    guard lines != 0 else { return }
    guard let index = values.indices.last, values[index].pane == pane else {
      values.append(Step(pane: pane, lines: lines))
      return
    }
    let (partial, overflow) = values[index].lines.addingReportingOverflow(lines)
    let sum = overflow ? (lines > 0 ? Int32.max : Int32.min) : partial
    if sum == 0 {
      values.removeLast()
    } else {
      values[index].lines = sum
    }
  }
}

enum TmuxTabError: LocalizedError {
  case noConnection
  var errorDescription: String? { "Not connected." }
}

/// Something in tmux with a name a person is editing.
public enum TmuxRename: Hashable {
  case session(TmuxSessionInfo)
  case window(TmuxListedWindow)

  public var name: String {
    switch self {
    case .session(let session): session.name
    case .window(let window): window.name
    }
  }
}
