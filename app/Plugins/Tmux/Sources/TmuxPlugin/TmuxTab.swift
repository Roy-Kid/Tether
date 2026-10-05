import SwiftUI
import Tether
import TetherPluginKit
import TetherUI

/// tmux on one terminal tab.
///
/// The tab's own terminal is the client. Choosing a session runs `tmux`
/// there — attach when the shell is free, switch-client when it is already
/// one — and the menus send the same kind of command. Nothing here draws
/// a pane of its own.
@MainActor @Observable
public final class TmuxTab: TabAttachment {
  public let tab: TabContext
  public var sessions: [TmuxSessionInfo] = []
  /// The session a tmux client on this tab's own shell tty is showing.
  public var shellSessionID: String?
  public var error: String?
  public var missing = false
  public var busy = false
  public var draftName = ""
  public private(set) var connection: RemoteConnection?
  public var sessionToEnd: TmuxSessionInfo?
  public var windowToEnd: TmuxListedWindow?
  /// The name being edited, while the rename dialog is open.
  public var renaming: TmuxRename?
  private var shellSessionName = ""
  private var operation: Task<Void, Never>?
  private var closed = false
  private let creation = SessionCreation()
  /// The tab, if any, whose shell is this session. One server's `$0` is not
  /// another's; the plugin matches host as well as id.
  private let owner: (String) -> TmuxTab?
  private let onClose: () -> Void
  /// The tty `shellSessionID` was learned from. A wheel is taken only while
  /// the shell is still that tty.
  private var shellTTY: String?
  /// When this shell was last asked whether it is a client. A full-screen
  /// program is asked at most once a second, and only because a wheel asked.
  private var shellChecked = Date.distantPast
  /// Notches for the shell's own client. One drainer lets a flick finish,
  /// then sends the whole gesture as one command.
  private var shellNotches = ShellNotches()
  private var shellLookup: Task<Void, Never>?
  private var shellScrollTask: Task<Void, Never>?
  /// The shell's client is showing its history. The next key puts it back
  /// at the prompt before the key is delivered.
  private var shellCopied = false
  /// Panes of the client's current window, and when they were read.
  /// A wheel over a program that asked for the mouse has to be reported;
  /// one over a shell is scrolled by the line, not by tmux's binding.
  private var panes: [TmuxPaneWheel]?
  private var panesAt = Date.distantPast
  private var paneTask: Task<Void, Never>?
  private var paneGeneration = 0

  init(tab: TabContext, owner: @escaping (String) -> TmuxTab?, onClose: @escaping () -> Void) {
    self.tab = tab
    self.connection = tab.plugin.connection
    self.owner = owner
    self.onClose = onClose
  }

  // MARK: - TabAttachment

  /// The terminal stays the terminal. tmux, when it is there, is what that
  /// terminal is showing.
  public var isShowing: Bool { false }
  public var subtitle: String {
    guard let id = shellSessionID else { return "" }
    return sessions.first { $0.id == id }?.name ?? shellSessionName
  }
  public var isDisconnected: Bool { false }
  public var closeNote: String? { shellSessionID == nil ? nil : "tmux stays on the host." }

  struct Restoration: Codable {
    let sessionID: String
    let sessionName: String
  }

  /// The tmux session this terminal is attached to, so reopening the tab can
  /// attach it again. A shell that has left tmux has nothing to restore.
  public var restorationState: Data? {
    guard let id = shellSessionID else { return nil }
    let name = shellSessionName.isEmpty
      ? (sessions.first { $0.id == id }?.name ?? "")
      : shellSessionName
    guard !name.isEmpty else { return nil }
    return try? JSONEncoder().encode(Restoration(sessionID: id, sessionName: name))
  }

  public func restore(from state: Data) {
    guard let saved = try? JSONDecoder().decode(Restoration.self, from: state) else { return }
    if connection == nil, let leased = tab.plugin.connection {
      connection = leased
    }
    run { [self] in
      sessions = try await lease().tmuxSessions()
      guard !closed, !Task.isCancelled else { return }
      guard let restored = sessions.first(where: {
        $0.id == saved.sessionID && $0.name == saved.sessionName
      }) else {
        error = "The previous tmux session is no longer available."
        return
      }
      // Another tab may have reattached while this one was closed.
      guard owner(restored.id) == nil || owner(restored.id) === self else { return }
      try await open(restored, windowID: nil)
    }
  }
  public var commands: [PluginCommand] {
    guard shellSessionID != nil else { return [] }
    return [
      PluginCommand(id: "detach", title: "Detach Session", symbol: "eject") { [weak self] in
        self?.detachSession()
      },
      PluginCommand(id: "newWindow", title: "New window", symbol: "plus.rectangle") { [weak self] in
        self?.newWindow()
      },
      PluginCommand(id: "splitHorizontal", title: "Split left and right", symbol: "rectangle.split.2x1") {
        [weak self] in self?.split(horizontal: true)
      },
      PluginCommand(id: "splitVertical", title: "Split top and bottom", symbol: "rectangle.split.1x2") {
        [weak self] in self?.split(horizontal: false)
      },
      PluginCommand(id: "zoom", title: "Zoom pane", symbol: "arrow.up.left.and.arrow.down.right") {
        [weak self] in self?.zoom()
      },
    ]
  }
  public func content() -> AnyView { AnyView(EmptyView()) }
  public func inspector() -> AnyView { AnyView(TmuxInspector(model: self)) }
  public func accessoryContent() -> AnyView { AnyView(TmuxPicker(model: self)) }
  public func connectionChanged(_ connection: RemoteConnection) {
    guard self.connection !== connection else { return }
    self.connection = connection
    shellLookup?.cancel()
    shellLookup = nil
    shellScrollTask?.cancel()
    forgetShellClient()
  }
  public func close() {
    closed = true
    operation?.cancel()
    shellLookup?.cancel()
    shellScrollTask?.cancel()
    onClose()
  }

  /// A wheel over the shell. Taken when this shell is already a client we
  /// have named, and held while that is still being learned.
  ///
  /// tmux may be drawing on the primary screen. Scrolling this terminal
  /// then moves the status line with every pane. The wheel waits, and goes
  /// to tmux when the answer is that this shell is the client. A shell that
  /// is not gets the lines back.
  public func scrollShell(_ lines: Int32, fullScreen _: Bool) -> Bool {
    let tty = tab.terminalName()
    if TmuxShellScroll.claims(
      connected: connection != nil, session: shellSessionID, tty: tty, knownTTY: shellTTY)
    {
      guard lines != 0 else { return true }
      shellNotches.add(lines)
      startShellDrain()
      return true
    }
    guard connection != nil else { return false }
    lookupShellClient()
    guard TmuxShellScroll.holds(
      connected: true, tty: tty, knownTTY: shellTTY, session: shellSessionID,
      lookupRunning: shellLookup != nil)
    else { return false }
    if lines != 0 { shellNotches.add(lines) }
    return true
  }

  /// A wheel the program asked to hear. Taken when this shell is that
  /// client, so the pane under the pointer moves by these lines.
  ///
  /// Reporting the notch instead lets tmux's own binding run: the first
  /// one only enters copy mode, each one after scrolls five rows, and one
  /// that lands on the status line changes window. A pane that is on the
  /// alternate screen, or that asked for the mouse, still hears the report.
  public func claimWheel(_ lines: Int32, column: UInt16, row: UInt16) -> Bool {
    let tty = tab.terminalName()
    if TmuxShellScroll.claims(
      connected: connection != nil, session: shellSessionID, tty: tty, knownTTY: shellTTY),
      let panes
    {
      let fresh = Date().timeIntervalSince(panesAt) < TmuxPaneLayout.ttl
      switch TmuxPaneLayout.decide(panes, column: Int(column), row: Int(row)) {
      case .report:
        // A program that asked for the mouse keeps the wheel. An old
        // answer is refreshed for the next notch, without holding this one.
        if !fresh { schedulePaneLoad() }
        return false
      case .ignore where fresh:
        return true
      case .scroll where fresh:
        break
      default:
        break
      }
    }
    if TmuxShellScroll.claims(
      connected: connection != nil, session: shellSessionID, tty: tty, knownTTY: shellTTY)
    {
      guard lines != 0 else { return true }
      shellNotches.add(lines, column: column, row: row, reported: true)
      startShellDrain()
      return true
    }
    guard connection != nil else { return false }
    lookupShellClient()
    guard TmuxShellScroll.holds(
      connected: true, tty: tty, knownTTY: shellTTY, session: shellSessionID,
      lookupRunning: shellLookup != nil)
    else { return false }
    if lines != 0 { shellNotches.add(lines, column: column, row: row, reported: true) }
    return true
  }

  public var shellInputWaits: Bool { shellCopied }

  public func restoreShellForInput() async {
    guard shellCopied else { return }
    shellCopied = false
    shellNotches = ShellNotches()
    let scrolling = shellScrollTask
    scrolling?.cancel()
    await scrolling?.value
    // The command already in flight may have entered copy mode. This is
    // about to cancel that, so the next key must not wait again.
    shellCopied = false
    shellNotches = ShellNotches()
    guard !closed, let session = shellSessionID, let connection,
      let command = TmuxShellScroll.cancel(session: session)
    else { return }
    _ = try? await connection.execute(command)
  }

  // MARK: - State

  public func windows(for session: TmuxSessionInfo) -> [TmuxListedWindow] {
    session.windows
  }

  // MARK: - Choosing

  /// Attaches `chosen` in this tab's terminal. A shell that is already that
  /// session only changes window. Another client of the same server switches.
  /// A plain shell is given `tmux attach-session`, which is what then draws.
  public func choose(_ chosen: TmuxSessionInfo, windowID: UInt32?) {
    if shellSessionID == chosen.id, windowID == nil {
      tab.dismissAccessory()
      return
    }
    run { [self] in
      try await open(chosen, windowID: windowID)
      guard !closed, !Task.isCancelled else { return }
      tab.dismissAccessory()
    }
  }

  /// Leaves tmux, so the shell that started it is on screen again.
  public func showShell() {
    guard shellSessionID != nil else {
      tab.dismissAccessory()
      return
    }
    detachSession { [weak self] in self?.tab.dismissAccessory() }
  }

  public func detachSession(then done: (@MainActor () -> Void)? = nil) {
    run { [self] in
      try await detachClient()
      guard !closed, !Task.isCancelled else { return }
      done?()
    }
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
          noteShellClient(tty: tty, session: try? await connection.tmuxSession(forClientTTY: tty))
        } else {
          noteShellClient(tty: nil, session: nil)
        }
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

  /// Reports success only after the new session is running in this terminal.
  /// The draft and error remain available to the presenting form when an
  /// operation fails.
  public func create(onSuccess: @escaping @MainActor () -> Void) {
    let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let directory = tab.workingDirectory()
    run { [self] in
      let connection = try lease()
      let created = try await creation.perform(
        name: name,
        create: { try await connection.createTmux(name: $0, directory: directory) },
        attach: { try await self.open($0, windowID: nil) })
      guard !closed, !Task.isCancelled else { return }
      adopt(created)
      draftName = ""
      onSuccess()
    }
  }

  public func endSession(_ ending: TmuxSessionInfo) {
    run { [self] in
      let connection = try lease()
      try await connection.endTmux(sessionID: ending.id)
      if shellSessionID == ending.id { forgetShellClient() }
      if let other = owner(ending.id), other !== self, other.shellSessionID == ending.id {
        other.forgetShellClient()
      }
      sessions = try await connection.tmuxSessions()
    }
  }

  /// Through the connection, not a second client: the window may belong to a
  /// session this terminal is not attached to.
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
    case .window(let window):
      run { [self] in
        guard let command = TmuxCommands.renameWindow(window.id, to: name) else {
          throw TmuxTabError.rejected(TmuxCommands.rejectedName)
        }
        try await exec(command)
        sessions = try await lease().tmuxSessions()
      }
    }
  }

  public func renameSession(_ renamed: TmuxSessionInfo, to name: String) {
    run { [self] in
      let connection = try lease()
      try await connection.renameTmux(sessionID: renamed.id, name: name)
      sessions = try await connection.tmuxSessions()
      if shellSessionID == renamed.id { shellSessionName = name }
    }
  }

  public func newWindow() { runOnSession { TmuxCommands.newWindow($0) } }
  public func split(horizontal: Bool) { runOnSession { TmuxCommands.split($0, horizontal: horizontal) } }
  public func zoom() { runOnSession { TmuxCommands.zoom($0) } }

  private func runOnSession(_ command: @escaping (String) -> String?) {
    run { [self] in
      guard let id = shellSessionID, let text = command(id) else {
        throw TmuxTabError.rejected(TmuxCommands.rejectedName)
      }
      try await exec(text)
    }
  }

  /// Puts `chosen` on this terminal.
  private func open(_ chosen: TmuxSessionInfo, windowID: UInt32?) async throws {
    let connection = try lease()
    // A remote tty is learned after connect. Attaching before that answer
    // would type into a client that is already there.
    guard let tty = await terminalTTY() else {
      throw TmuxTabError.rejected("This terminal has no name yet.")
    }
    if closed || Task.isCancelled { return }
    let current = try await connection.tmuxSession(forClientTTY: tty)
    if closed || Task.isCancelled { return }
    noteShellClient(tty: tty, session: current)
    if let current {
      if current == chosen.id {
        if let windowID { try await exec(TmuxCommands.selectWindow(windowID)) }
        adopt(chosen)
        return
      }
      guard let command = TmuxCommands.switchClient(tty: tty, session: chosen.id) else {
        throw TmuxTabError.rejected(TmuxCommands.rejectedName)
      }
      try await exec(command)
      noteShellClient(tty: tty, session: chosen.id)
      adopt(chosen)
      if let windowID { try await exec(TmuxCommands.selectWindow(windowID)) }
      return
    }
    guard let line = TmuxCommands.attachLine(name: chosen.name, id: chosen.id, window: windowID) else {
      throw TmuxTabError.rejected(TmuxCommands.rejectedName)
    }
    tab.runInTerminal(line)
  }

  private func detachClient() async throws {
    let command: String?
    if let tty = tab.terminalName() ?? shellTTY {
      command = TmuxCommands.detach(tty: tty)
    } else if let id = shellSessionID {
      command = TmuxCommands.detachSession(id)
    } else {
      command = nil
    }
    guard let command else { throw TmuxTabError.noConnection }
    try await exec(command)
    forgetShellClient()
  }

  /// Runs `command` and surfaces a non-zero status as the error a person sees.
  private func exec(_ command: String) async throws {
    let output = try await lease().execute(command)
    guard (output.status ?? 1) == 0 else {
      let data = output.stderr.isEmpty ? output.stdout : output.stderr
      let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw TmuxTabError.rejected((text?.isEmpty == false) ? text! : "The command failed.")
    }
  }

  /// The shell's tty, waiting briefly when a remote session has not learned
  /// it yet. Unknown stays unknown: attaching before that is known is how a
  /// second client used to cover the one already on screen.
  private func terminalTTY() async -> String? {
    if let tty = tab.terminalName() { return tty }
    for _ in 0..<10 {
      if closed || Task.isCancelled { return nil }
      try? await Task.sleep(for: .milliseconds(200))
      if let tty = tab.terminalName() { return tty }
    }
    return nil
  }

  private func adopt(_ session: TmuxSessionInfo) {
    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[index] = session
    } else {
      sessions.append(session)
    }
    if shellSessionID == session.id { shellSessionName = session.name }
  }

  /// One command for one gesture. A flick is many notches inside a frame
  /// or two; sending the first alone starts a shell for a single line and
  /// holds the rest for that round trip. Scrolling back is what says the
  /// client is still there: a failure forgets it. Scrolling forward while
  /// nothing is in copy mode is ordinary and stays quiet.
  private func drainShellScroll() async {
    defer { shellScrollTask = nil }
    while !closed, !Task.isCancelled {
      let held = await nextShellLines()
      guard held.lines != 0, !closed, !Task.isCancelled else { return }
      if held.reported {
        await applyReported(held)
      } else if let session = shellSessionID {
        await apply(target: session, held: held)
      }
    }
  }

  /// A wheel that was going to be reported. The pane under the pointer
  /// decides: a shell is scrolled by these lines, a program that asked for
  /// the mouse hears the report, and the status line is left alone.
  private func applyReported(_ held: HeldWheel) async {
    let layout = await panesForWheel()
    guard let layout else {
      giveReported(held)
      return
    }
    switch TmuxPaneLayout.decide(layout, column: Int(held.column), row: Int(held.row)) {
    case .ignore:
      return
    case .report:
      giveReported(held)
    case .scroll(let pane):
      await apply(target: pane, held: held)
    }
  }

  private func giveReported(_ held: HeldWheel) {
    let magnitude = min(Int(held.lines.magnitude), TmuxShellScroll.repeatCap)
    guard magnitude > 0 else { return }
    let applied: Int32 = held.lines > 0 ? Int32(magnitude) : -Int32(magnitude)
    tab.reportWheel(applied, held.column, held.row)
    let (rest, overflowed) = held.lines.subtractingReportingOverflow(applied)
    if !overflowed, rest != 0 {
      shellNotches.add(rest, column: held.column, row: held.row, reported: true)
      startShellDrain()
    }
  }

  private func apply(target: String, held: HeldWheel) async {
    guard let connection, let built = TmuxShellScroll.command(target: target, lines: held.lines)
    else { return }
    let (rest, overflowed) = held.lines.subtractingReportingOverflow(built.applied)
    if !overflowed, rest != 0 {
      shellNotches.add(rest, column: held.column, row: held.row, reported: held.reported)
    }
    let output: CommandOutput
    do {
      output = try await connection.execute(built.text)
    } catch {
      if Task.isCancelled || closed { return }
      if built.applied > 0 { forgetShellClient() } else { shellNotches = ShellNotches() }
      return
    }
    if Task.isCancelled || closed { return }
    if built.applied > 0 {
      if (output.status ?? 1) != 0 {
        forgetShellClient()
        return
      }
      shellCopied = true
    } else if (output.status ?? 1) != 0 {
      shellCopied = false
    }
  }

  /// The lines of one gesture: wait one frame, and a second if the wheel
  /// is still moving, then send whatever has arrived. A cancelled sleep
  /// throws, and `try?` swallows it, so cancellation is read afterwards.
  private func nextShellLines() async -> HeldWheel {
    var seen = shellNotches.lines
    for _ in 0..<2 {
      if seen == 0 || closed || Task.isCancelled { return .empty }
      try? await Task.sleep(for: .milliseconds(16))
      if closed || Task.isCancelled { return .empty }
      let now = shellNotches.lines
      if now == seen { break }
      seen = now
    }
    if closed || Task.isCancelled { return .empty }
    return shellNotches.take()
  }

  private func startShellDrain() {
    guard shellScrollTask == nil else { return }
    shellScrollTask = Task { [weak self] in await self?.drainShellScroll() }
  }

  /// The lines held for a lookup. A client scrolls them; anything else is
  /// given back to this terminal, which was not moved while we asked.
  private func deliver(tty: String, session: String?) {
    noteShellClient(tty: tty, session: session)
    guard !closed else {
      shellNotches = ShellNotches()
      return
    }
    if session == nil {
      let pending = shellNotches.take()
      if pending.lines != 0 {
        if pending.reported {
          giveReported(pending)
        } else {
          tab.scrollBy(pending.lines)
        }
      }
      return
    }
    if shellNotches.lines != 0 { startShellDrain() }
  }

  /// Asks whether this shell is a client. The same tty is not asked again
  /// within a second, so a program that merely fills the screen is not
  /// polled on every notch. A full-screen program is not the only reason
  /// to ask: tmux on the primary screen is the case where this terminal
  /// would otherwise scroll the whole window.
  private func lookupShellClient() {
    guard shellLookup == nil, connection != nil, !closed else { return }
    let tty = tab.terminalName()
    let recent = Date().timeIntervalSince(shellChecked) < 1
    if recent, tty == nil || tty == shellTTY { return }
    shellChecked = Date()
    shellLookup = Task { [weak self] in
      await self?.findShellClient()
      self?.shellLookup = nil
    }
  }

  /// Retries while the tty is still unknown: a remote shell learns it after
  /// connect. An answer records the tty either way, so a shell that is not
  /// a client is not asked again until the wheel comes back.
  private func findShellClient() async {
    guard let connection else { return }
    for attempt in 0..<15 {
      if closed || Task.isCancelled { return }
      guard let tty = tab.terminalName() else {
        if attempt == 14 { return }
        try? await Task.sleep(for: .milliseconds(200))
        continue
      }
      do {
        let found = try await connection.tmuxSession(forClientTTY: tty)
        if closed || Task.isCancelled { return }
        guard tab.terminalName() == tty else { continue }
        deliver(tty: tty, session: found)
        return
      } catch {
        if closed || Task.isCancelled { return }
        // The tty is known and the question failed. Retrying would keep the
        // wheel from this terminal for the whole wait.
        if shellSessionID == nil { deliver(tty: tty, session: nil) }
        return
      }
    }
  }

  private func noteShellClient(tty: String?, session: String?) {
    let changed = session != shellSessionID
    if changed { shellCopied = false }
    shellTTY = tty
    shellSessionID = session
    if let session, let known = sessions.first(where: { $0.id == session }) {
      shellSessionName = known.name
    } else if session == nil {
      shellSessionName = ""
    }
    if changed { invalidatePanes() }
    if session != nil, panes == nil { schedulePaneLoad() }
  }

  fileprivate func forgetShellClient() {
    shellSessionID = nil
    shellTTY = nil
    shellSessionName = ""
    shellChecked = .distantPast
    shellNotches = ShellNotches()
    shellCopied = false
    invalidatePanes()
  }

  private func invalidatePanes() {
    panes = nil
    panesAt = .distantPast
    paneGeneration += 1
    paneTask?.cancel()
    paneTask = nil
  }

  /// The layout a reported wheel is decided against. A fresh one is used
  /// as it stands. An old one is read again first: the pane may have
  /// started a program that wants the mouse since the last wheel.
  private func panesForWheel() async -> [TmuxPaneWheel]? {
    if let panes, Date().timeIntervalSince(panesAt) < TmuxPaneLayout.ttl { return panes }
    if paneTask == nil { schedulePaneLoad() }
    await paneTask?.value
    return panes
  }

  private func schedulePaneLoad() {
    guard paneTask == nil, connection != nil, shellSessionID != nil, !closed else { return }
    let generation = paneGeneration
    paneTask = Task { [weak self] in
      await self?.fetchPanes(generation: generation)
    }
  }

  private func fetchPanes(generation: Int) async {
    defer {
      if paneGeneration == generation { paneTask = nil }
    }
    guard !closed, !Task.isCancelled, paneGeneration == generation, let session = shellSessionID,
      let command = TmuxPaneLayout.listCommand(session: session), let connection
    else { return }
    guard let output = try? await connection.execute(command), (output.status ?? 1) == 0,
      shellSessionID == session, paneGeneration == generation, !Task.isCancelled,
      let text = String(data: output.stdout, encoding: .utf8),
      let parsed = TmuxPaneLayout.parse(text)
    else { return }
    panes = parsed
    panesAt = Date()
  }
}

/// Commands the menu runs. A session id is only ever `$` and digits, and a
/// name is quoted the way tmux quotes one: a control character is refused
/// rather than escaped into the shell.
enum TmuxCommands {
  static let rejectedName =
    "Names must be shorter than 1025 bytes and contain no control characters"

  static func quote(_ value: String) -> String? {
    if value.isEmpty || value.utf8.count > 1024
      || value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    {
      return nil
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func sessionID(_ id: String) -> String? {
    guard id.count > 1, id.count <= 20, id.first == "$",
      id.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    return "'\(id)'"
  }

  /// The line a free shell runs, so tmux draws in this terminal.
  static func attachLine(name: String, id: String, window: UInt32?) -> String? {
    guard let target = quote(name) ?? sessionID(id) else { return nil }
    var line = "tmux attach-session -t \(target)"
    if let window { line += " \\; select-window -t @\(window)" }
    return line
  }

  static func switchClient(tty: String, session: String) -> String? {
    guard let tty = quote(tty), let session = sessionID(session) else { return nil }
    return "tmux switch-client -c \(tty) -t \(session)"
  }

  static func selectWindow(_ id: UInt32) -> String { "tmux select-window -t @\(id)" }

  static func newWindow(_ session: String) -> String? {
    sessionID(session).map { "tmux new-window -t \($0)" }
  }

  static func split(_ session: String, horizontal: Bool) -> String? {
    guard let session = sessionID(session) else { return nil }
    return "tmux split-window \(horizontal ? "-h" : "-v") -t \(session)"
  }

  static func zoom(_ session: String) -> String? {
    sessionID(session).map { "tmux resize-pane -Z -t \($0)" }
  }

  static func detach(tty: String) -> String? {
    quote(tty).map { "tmux detach-client -t \($0)" }
  }

  static func detachSession(_ session: String) -> String? {
    sessionID(session).map { "tmux detach-client -s \($0)" }
  }

  static func renameWindow(_ id: UInt32, to name: String) -> String? {
    quote(name).map { "tmux rename-window -t @\(id) \($0)" }
  }
}

/// Lines waiting for the shell's own client. Opposite notches that cancel
/// are nothing to send.
struct HeldWheel: Equatable {
  var lines: Int32
  var column: UInt16
  var row: UInt16
  var reported: Bool

  static let empty = HeldWheel(lines: 0, column: 0, row: 0, reported: false)
}

struct ShellNotches: Equatable {
  private(set) var lines: Int32 = 0
  private var column: UInt16 = 0
  private var row: UInt16 = 0
  private var reported = false

  mutating func add(
    _ lines: Int32, column: UInt16 = 0, row: UInt16 = 0, reported: Bool = false
  ) {
    guard lines != 0 else { return }
    let (partial, overflow) = self.lines.addingReportingOverflow(lines)
    self.lines = overflow ? (lines > 0 ? Int32.max : Int32.min) : partial
    self.column = column
    self.row = row
    self.reported = reported
  }

  mutating func take() -> HeldWheel {
    defer {
      lines = 0
      column = 0
      row = 0
      reported = false
    }
    return HeldWheel(lines: lines, column: column, row: row, reported: reported)
  }
}

/// What a wheel over the shell's own client asks for.
///
/// The session id is the only part that changes, and it is only ever `$`
/// and digits: that string is quoted into a shell command.
struct TmuxShellCommand: Equatable {
  var text: String
  var applied: Int32
}

enum TmuxShellScroll {
  /// How many lines one command will repeat. A swipe can ask for more;
  /// the rest goes in the next command.
  static let repeatCap = 500

  static func command(session: String, lines: Int32) -> TmuxShellCommand? {
    guard isSessionID(session) else { return nil }
    return command(target: session, lines: lines)
  }

  /// `target` is a session id (`$` and digits) or a pane id (`%` and digits).
  static func command(target: String, lines: Int32) -> TmuxShellCommand? {
    guard lines != 0, isTarget(target) else { return nil }
    let magnitude = min(Int(lines.magnitude), repeatCap)
    guard magnitude > 0 else { return nil }
    let applied: Int32 = lines > 0 ? Int32(magnitude) : -Int32(magnitude)
    let quoted = "'\(target)'"
    if lines > 0 {
      return TmuxShellCommand(
        text: "tmux copy-mode -e -t \(quoted) \\; send-keys -X -N \(magnitude) -t \(quoted) scroll-up",
        applied: applied)
    }
    return TmuxShellCommand(
      text: "tmux send-keys -X -N \(magnitude) -t \(quoted) scroll-down",
      applied: applied)
  }

  static func cancel(session: String) -> String? {
    guard isSessionID(session) else { return nil }
    return "tmux send-keys -X -t '\(session)' cancel"
  }

  static func claims(
    connected: Bool, session: String?, tty: String?, knownTTY: String?
  ) -> Bool {
    guard connected, let session, let tty, tty == knownTTY else { return false }
    return command(session: session, lines: 1) != nil
  }

  /// Whether a wheel that is not already claimed should be held. A lookup
  /// still in flight for a tty we have not settled is one: scrolling this
  /// terminal now would move the whole window if the answer is tmux.
  /// A tty already known not to be a client is not held, even mid-refresh.
  static func holds(
    connected: Bool, tty: String?, knownTTY: String?, session: String?,
    lookupRunning: Bool
  ) -> Bool {
    guard connected, let tty, lookupRunning else { return false }
    if session == nil, tty == knownTTY { return false }
    return true
  }

  private static func isSessionID(_ text: String) -> Bool {
    isIdentifier(text, mark: "$")
  }

  private static func isTarget(_ text: String) -> Bool {
    isIdentifier(text, mark: "$") || isIdentifier(text, mark: "%")
  }

  private static func isIdentifier(_ text: String, mark: Character) -> Bool {
    text.count > 1 && text.count <= 20 && text.first == mark
      && text.dropFirst().allSatisfy { $0 >= "0" && $0 <= "9" }
  }
}

/// One pane of the client's current window, in that window's cells.
struct TmuxPaneWheel: Equatable {
  var id: String
  var left: Int
  var top: Int
  var width: Int
  var height: Int
  var alternate: Bool
  var wantsMouse: Bool
  var inMode: Bool
  var active: Bool
  var zoomed: Bool
  var windowHeight: Int
  var statusLines: Int
  var statusTop: Bool
}

/// Where a reported wheel should go. The status line and the borders are
/// not a pane: scrolling them is how a window changes under the pointer.
enum TmuxWheelTarget: Equatable {
  case report
  case scroll(String)
  case ignore
}

enum TmuxPaneLayout {
  /// How long a layout may decide a wheel before it is read again.
  static let ttl: TimeInterval = 0.3

  static let format =
    "#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{alternate_on}|#{mouse_any_flag}|#{pane_in_mode}|#{pane_active}|#{window_zoomed_flag}|#{window_height}|#{status-position}|#{status}"

  static func listCommand(session: String) -> String? {
    guard session.count > 1, session.count <= 20, session.first == "$",
      session.dropFirst().allSatisfy({ $0 >= "0" && $0 <= "9" })
    else { return nil }
    return "tmux list-panes -t '\(session)' -F '\(format)'"
  }

  static func parse(_ text: String) -> [TmuxPaneWheel]? {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard !lines.isEmpty else { return nil }
    var panes: [TmuxPaneWheel] = []
    for line in lines {
      guard let pane = parseLine(line) else { return nil }
      panes.append(pane)
    }
    return panes
  }

  /// The pane under a terminal cell. `row` counts from the top of the
  /// terminal, which is where the status line sits when it is on top.
  static func decide(_ panes: [TmuxPaneWheel], column: Int, row: Int) -> TmuxWheelTarget {
    guard column >= 0, row >= 0, let sample = panes.first else { return .report }
    if sample.statusTop {
      if row < sample.statusLines { return .ignore }
    } else if sample.statusLines > 0, row >= sample.windowHeight {
      return .ignore
    }
    let paneRow = row - (sample.statusTop ? sample.statusLines : 0)
    let visible = panes.filter { !$0.zoomed || $0.active }
    guard let pane = visible.first(where: { hit($0, column: column, row: paneRow) }) else {
      return .ignore
    }
    if pane.inMode || (!pane.alternate && !pane.wantsMouse) {
      return .scroll(pane.id)
    }
    return .report
  }

  private static func hit(_ pane: TmuxPaneWheel, column: Int, row: Int) -> Bool {
    column >= pane.left && column < pane.left + pane.width && row >= pane.top
      && row < pane.top + pane.height
  }

  private static func parseLine(_ line: String) -> TmuxPaneWheel? {
    let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 13 else { return nil }
    guard isPaneID(parts[0]),
      let left = coordinate(parts[1]), let top = coordinate(parts[2]),
      let width = dimension(parts[3]), let height = dimension(parts[4]),
      let alternate = flag(parts[5]), let wantsMouse = flag(parts[6]),
      let inMode = flag(parts[7]), let active = flag(parts[8]),
      let zoomed = flag(parts[9]), let windowHeight = dimension(parts[10]),
      let statusTop = statusPosition(parts[11]), let lines = statusCount(parts[12])
    else { return nil }
    return TmuxPaneWheel(
      id: parts[0], left: left, top: top, width: width, height: height,
      alternate: alternate, wantsMouse: wantsMouse, inMode: inMode, active: active,
      zoomed: zoomed, windowHeight: windowHeight, statusLines: lines,
      statusTop: statusTop)
  }

  private static func isPaneID(_ text: String) -> Bool {
    text.count > 1 && text.count <= 20 && text.first == "%"
      && text.dropFirst().allSatisfy { $0 >= "0" && $0 <= "9" }
  }

  private static func coordinate(_ text: String) -> Int? {
    guard let value = Int(text), value >= 0, value < 10_000 else { return nil }
    return value
  }

  private static func dimension(_ text: String) -> Int? {
    guard let value = Int(text), value > 0, value <= 10_000 else { return nil }
    return value
  }

  private static func flag(_ text: String) -> Bool? {
    switch text {
    case "0": return false
    case "1": return true
    default: return nil
    }
  }

  private static func statusPosition(_ text: String) -> Bool? {
    switch text {
    case "top": return true
    case "bottom": return false
    default: return nil
    }
  }

  private static func statusCount(_ text: String) -> Int? {
    switch text {
    case "off": return 0
    case "on": return 1
    default:
      guard let value = Int(text), (0...5).contains(value) else { return nil }
      return value
    }
  }
}

enum TmuxTabError: LocalizedError {
  case noConnection
  case rejected(String)
  var errorDescription: String? {
    switch self {
    case .noConnection: "Not connected."
    case .rejected(let reason): reason
    }
  }
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
