import Foundation
import Observation
import Tether
import TetherPluginKit
import TetherUI

/// What a tab is currently doing.
enum Stage {
  case connecting
  /// The handshake is waiting on a person: a host to trust, or answers to
  /// give. The connection is genuinely blocked until it is resolved.
  case asking
  case connected
  case failed(String)
  case ended(String?)
}

/// A tab plugin's attachment, and whose it is.
struct TabAttachmentEntry {
  let pluginID: String
  let attachment: any TabAttachment
}

/// One open session — one tab.
@MainActor
@Observable
final class SessionTab: Identifiable {
  let id = UUID()
  /// The host as it was when this tab last dialled.
  private(set) var host: Host
  /// Stable work-position name (`Terminal 1`), not the remote title.
  var name: String

  private(set) var stage: Stage = .connecting
  private(set) var frame: ScreenFrame?
  /// `nil` means every row is new. An empty set means only the cursor moved.
  private(set) var dirtyRows: Set<Int>?
  private(set) var remoteTitle: String = ""

  /// Primary tab label. Identity is `id`, never this string.
  var title: String { name }

  /// What the tab shows next to the name: whatever stands in for the shell
  /// says what it is, and the shell itself says nothing. The remote OSC
  /// title stays in the terminal; it is not the tab's identity.
  var subtitle: String { shown?.subtitle ?? "" }

  /// What tab plugins keep on this tab, in the order they first opened here.
  private(set) var attachments: [TabAttachmentEntry] = []

  /// Something the person has to be told, until they have been.
  private(set) var problem: SessionProblem?
  /// A password that has just worked and could be kept, until answered.
  private(set) var passwordOffer: PasswordOffer?
  /// Whether a working password may be offered to be kept. Off once the
  /// person has said no for this host.
  var offersToSave = true {
    didSet { if !offersToSave { passwordOffer = nil } }
  }
  /// Called when the person declined a question this tab's login asked:
  /// a decision, not a failure, and nothing is left for the tab to show.
  var onDeclined: (() -> Void)?

  /// The attachment standing in for the shell, if one is.
  var shown: (any TabAttachment)? {
    attachments.first { $0.attachment.isShowing }?.attachment
  }

  var isLive: Bool {
    if case .connected = stage { return true }
    return false
  }

  /// The handshake is still in flight: waiting on the network, or on a person.
  var isHandshaking: Bool {
    switch stage {
    case .connecting, .asking: true
    default: false
    }
  }

  private var session: TerminalSession?
  var connection: RemoteConnection? { session?.connection }
  private var closed = false
  private var ready: [CheckedContinuation<RemoteConnection, Error>] = []
  private var pump: Task<Void, Never>?
  private var dialTask: Task<Void, Never>?
  private var authentication: AuthenticationCoordinator?

  private var columns: UInt16 = 80
  private var rows: UInt16 = 24
  /// The far-side tty, once a listing has named it. A local shell already
  /// has one on the session; this is only for a connection that does not.
  private var shellTTY: String?
  private var ttySearch: Task<Void, Never>?
  /// Set when the view has reported a size. Until then the pty is still the
  /// 80×24 it was opened at, which cannot pick this shell out of several.
  private var sized = false
  /// The tab on screen, and the app in front. A hidden tab still waits on
  /// the session, so a burst is not lost, but it does not copy a frame
  /// until someone is looking at it.
  private var publishesFrames = false
  /// Keys waiting on an attachment to put the shell back at its prompt,
  /// and how many have been queued. Later keys stay in order behind them.
  private var keyQueue: Task<Void, Never>?
  private var keySerial = 0
  /// What the window draws with, held so a session that opens later is told
  /// the same thing the one before it was.
  private var palette: TerminalPalette?

  private let known: KnownHosts
  /// Whether the password handed to the dial was typed just now, rather
  /// than read from the keychain: typed, it is worth offering to keep.
  private var typedNow = false

  init(host: Host, password: String, typedNow: Bool = false, known: KnownHosts, name: String) {
    self.host = host
    self.known = known
    self.name = name
    self.typedNow = typedNow
    dialTask = Task { await dial(password) }
  }

  /// A tab that opens a shell on a connection that is already authenticated.
  init(host: Host, connection: RemoteConnection, known: KnownHosts, name: String) {
    self.host = host
    self.known = known
    self.name = name
    dialTask = Task { await attach(connection) }
  }

  /// A tab that does not dial. Ownership tests need the object, not a PTY.
  init(preview host: Host, known: KnownHosts, name: String, live: Bool) {
    self.host = host
    self.known = known
    self.name = name
    self.stage = live ? .connected : .ended(nil)
  }

  private func dial(_ password: String) async {
    if host.isLocal { await open(); return }
    if let issue = host.connectionProblem {
      fail(IdentityError.storage(issue)); return
    }
    if host.allowsMasterReuse, await TerminalSession.sshMasterIsRunning(host.sshTarget) {
      do { adopt(try await TerminalSession.connectOverSsh(host.sshTarget, columns: columns, rows: rows)) }
      catch { fail(error) }
      return
    }
    // The coordinator holds the password for the handshake, and only the
    // coordinator: it is gone from memory once the attempt ends either way.
    let coordinator = AuthenticationCoordinator(host: host, password: password, known: known,
      ask: { [weak self] question, shown in await self?.ask(question, shown: shown) })
    authentication = coordinator
    defer { coordinator.cancel(); authentication = nil }
    do {
      adopt(try await coordinator.connect(columns: columns, rows: rows))
      // Only a password the login is known to have used: one typed at the
      // server's own prompt, or the one given before dialling when nothing
      // else could have logged in. A key that got there first proves nothing.
      offer(coordinator.typedPassword ?? (typedNow && coordinator.passwordProven ? password : nil))
    } catch {
      fail(error)
    }
  }

  /// Dials again in this tab: after a failure, or after the shell went away.
  /// `host` is the host as it is now — a label edited or a password kept
  /// since this tab opened belongs to the next attempt.
  func redial(host: Host, password: String, typedNow: Bool) {
    guard !closed, host.id == self.host.id else { return }
    self.host = host
    problem = nil
    passwordOffer = nil
    pump?.cancel()
    pump = nil
    session?.close()
    session = nil
    ttySearch?.cancel()
    shellTTY = nil
    frame = nil
    dirtyRows = nil
    stage = .connecting
    self.typedNow = typedNow
    dialTask = Task { await dial(password) }
  }

  /// The person has read the problem.
  func acknowledge() {
    problem = nil
  }

  /// A password that worked, offered to be kept.
  func offer(_ password: String?) {
    guard offersToSave, !host.isLocal, !closed, let password, !password.isEmpty else { return }
    passwordOffer = PasswordOffer(password: password)
  }

  /// The offer was answered, either way. The password leaves memory here.
  func settlePasswordOffer() {
    passwordOffer = nil
  }

  /// Opens a shell on a lease that has already been authenticated.
  ///
  /// Another channel, not another handshake: the password and whatever else
  /// the server asked were spent getting the connection this tab is holding.
  private func attach(_ connection: RemoteConnection) async {
    do {
      let session = try await connection.openShell(columns: columns, rows: rows)
      adopt(session)
    } catch {
      fail(error)
    }
  }

  /// Opens a shell on this machine.
  ///
  /// No trust question and no credentials, because there is no stranger to
  /// establish either with. What it hands back is the same `TerminalSession`
  /// a dial returns, which is why it can join the same repaint loop on the
  /// last line — and why the last few lines of this are the last few lines
  /// of `dial`, down to handing out the same lease.
  private func open() async {
    do {
      let session = try await TerminalSession.local(
        LocalShell(term: "xterm-256color", columns: columns, rows: rows))
      adopt(session)
    } catch {
      fail(error)
    }
  }

  private func adopt(_ session: TerminalSession) {
    guard !closed else {
      session.close()
      return
    }
    self.session = session
    // Before the first byte where possible: a program can ask what the
    // background is in its first breath, and an unanswered question is
    // answered by the convention that a terminal is dark.
    try? session.setPalette(palette)
    identifyShellTTY()
    // One wrapper for everyone waiting on this lease. A later read of
    // `connection` builds another, so the object handed out here is the
    // one a plugin can recognise as the lease it was given.
    if let connection = session.connection {
      ready.forEach { $0.resume(returning: connection) }
      ready.removeAll()
      // The shell was dialled again in this same tab. Attachments still
      // hold the lease that died — the files browser in particular — and
      // nothing else tells them the one in `session` replaced it.
      for entry in attachments {
        entry.attachment.connectionChanged(connection)
      }
    }
    stage = .connected
    frame = session.frame()
    startPumping(session)
  }

  /// Every failure is told, once, by name — except the person's own no,
  /// which ends the tab without a word.
  func fail(_ error: Error) {
    stage = .failed(message(for: error))
    ready.forEach { $0.resume(throwing: error) }
    ready.removeAll()
    guard !closed else { return }
    if error is CancellationError {
      onDeclined?()
      return
    }
    problem = SessionProblem(
      kind: .couldNotConnect, reason: message(for: error), refusedLogin: Self.refusesLogin(error))
  }

  /// The server turned down what it was offered, as opposed to never being
  /// reached or refusing a shell.
  private static func refusesLogin(_ error: Error) -> Bool {
    switch error as? TetherError {
    case .authenticationFailed, .moreFactorsNeeded, .nothingToOffer: true
    default: false
    }
  }

  /// Bumped by a resize. A repaint already in flight may have copied the
  /// screen from before it, and publishing that copy would put the old
  /// grid back. The resize itself has already drawn the screen as it is.
  private var resizeEpoch = 0

  /// Repaints when the screen changes, and not otherwise.
  ///
  /// No timer while the screen is still: the session wakes this loop on the
  /// first byte. A burst is then folded into one snapshot per refresh.
  /// Copying the grid on the main actor is what made a `cat` or `btop` drop
  /// frames — the lock and the Swift strings were competing with the keyboard.
  private func startPumping(_ session: TerminalSession) {
    pump = Task { [weak self] in
      while await session.awaitChange() {
        guard let self, !Task.isCancelled else { return }
        let pause = ProcessInfo.processInfo.isLowPowerModeEnabled ? 33 : 8
        do { try await Task.sleep(for: .milliseconds(pause)) } catch { return }
        guard !Task.isCancelled else { return }
        // A program's copy (`OSC 52`) is delivered on the same wake as the
        // bytes that carried it. Taken even when this tab is hidden, so a
        // later show does not dump a stale copy onto the pasteboard. Written
        // only while this tab is the one on screen.
        let copied = await Self.takeClipboard(session)
        if self.publishesFrames, let copied { copyToPasteboard(copied) }
        // The wake is consumed either way. Showing the tab later copies
        // whatever the screen is then, rather than every intermediate one.
        guard self.publishesFrames else { continue }
        let epoch = self.resizeEpoch
        let update = await Self.copyUpdate(session)
        guard !Task.isCancelled, self.publishesFrames else { continue }
        // A resize landed while this copy was in flight. The copy may be
        // the grid from before it; the screen now is the one to draw.
        if self.resizeEpoch != epoch {
          self.frame = session.frame()
          self.dirtyRows = nil
          continue
        }
        self.publish(update, session: session)
      }

      // One last repaint. The final frame is announced before the
      // ending is, so stopping here would leave a program's last line
      // undrawn.
      guard let self else { return }
      let copied = await Self.takeClipboard(session)
      if self.publishesFrames, let copied { copyToPasteboard(copied) }
      self.publish(await Self.copyUpdate(session), session: session)
      self.finish(session.ending())
    }
  }

  /// The grid copy, off the main actor. `TerminalSession` is `Sendable`;
  /// the lock that makes that true lives in Rust.
  private nonisolated static func copyUpdate(_ session: TerminalSession) async -> FrameUpdate {
    await Task.detached(priority: .userInitiated) { session.update() }.value
  }

  /// A remote copy, off the main actor. Same lock as the grid, taken
  /// separately so a clipboard request is not dropped with the damage.
  private nonisolated static func takeClipboard(_ session: TerminalSession) async -> String? {
    await Task.detached(priority: .userInitiated) { session.takeClipboard() }.value
  }

  /// Applies a partial update onto the frame already on screen. A full
  /// update replaces it. With no frame yet, the whole screen is taken,
  /// because a list of dirty rows has nothing to patch.
  private func publish(_ update: FrameUpdate, session: TerminalSession) {
    switch update {
    case .full(let frame):
      self.frame = frame
      dirtyRows = nil
      remoteTitle = frame.title
    case .rows(let rows, let cursorRow, let cursorColumn, let cursorShape, let cursorVisible, let title, let viewportOffset, let historyLines, let mouse):
      guard let current = frame else {
        self.frame = session.frame()
        dirtyRows = nil
        remoteTitle = self.frame?.title ?? title
        return
      }
      self.frame = patched(
        current, rows: rows, cursorRow: cursorRow, cursorColumn: cursorColumn,
        cursorShape: cursorShape, cursorVisible: cursorVisible, title: title,
        viewportOffset: viewportOffset, historyLines: historyLines, mouse: mouse)
      dirtyRows = Set(rows.map { Int($0.row) })
      remoteTitle = title
    case .idle(let cursorRow, let cursorColumn, let cursorShape, let cursorVisible, let title, let viewportOffset, let historyLines, let mouse):
      guard let current = frame else { return }
      self.frame = ScreenFrame(
        columns: current.columns, rows: current.rows, cursorRow: cursorRow,
        cursorColumn: cursorColumn, cursorShape: cursorShape, cursorVisible: cursorVisible,
        alternateScreen: current.alternateScreen, mouse: mouse, viewportOffset: viewportOffset,
        historyLines: historyLines, title: title, lines: current.lines)
      dirtyRows = []
      remoteTitle = title
    }
  }

  /// Turns copying on for the tab someone is looking at, and pulls the
  /// screen it has now. Hidden tabs keep their last frame until then.
  func setPublishesFrames(_ publishing: Bool) {
    guard publishing != publishesFrames else { return }
    publishesFrames = publishing
    guard publishing, let session, !closed else { return }
    Task { [weak self] in
      let update = await Self.copyUpdate(session)
      guard let self, self.publishesFrames, !self.closed else { return }
      self.publish(update, session: session)
    }
  }

  private func patched(
    _ current: ScreenFrame, rows: [UpdatedRow], cursorRow: UInt32, cursorColumn: UInt32,
    cursorShape: CaretShape, cursorVisible: Bool, title: String, viewportOffset: UInt32,
    historyLines: UInt32, mouse: MouseTracking
  ) -> ScreenFrame {
    var lines = current.lines
    for row in rows {
      let index = Int(row.row)
      guard lines.indices.contains(index) else { continue }
      lines[index] = row.line
    }
    return ScreenFrame(
      columns: current.columns, rows: current.rows, cursorRow: cursorRow,
      cursorColumn: cursorColumn, cursorShape: cursorShape, cursorVisible: cursorVisible,
      alternateScreen: current.alternateScreen, mouse: mouse, viewportOffset: viewportOffset,
      historyLines: historyLines, title: title, lines: lines)
  }

  /// Drops history above 200 lines. The cap stays for the life of the session.
  func releaseHistory() {
    session?.releaseHistory(keep: 200)
  }

  func pauseReading() {
    session?.pause()
  }

  func resumeReading() {
    session?.resume()
  }

  private func finish(_ ending: SessionEnding?) {
    let reason: String? =
      switch ending {
      case .lost(let cause): cause
      case .exited(let status) where status != 0:
        "The shell exited with status \(status)."
      default: nil
      }
    stage = .ended(reason)
    session = nil
    guard case .lost(let cause) = ending, !closed else { return }
    problem = SessionProblem(kind: .lost, reason: cause)
  }

  func send(_ input: TerminalInput) {
    // Shift-Page Up reads the history; Page Up on its own goes to the far
    // side, because a pager expects it. This is the split every terminal
    // makes, and making it here keeps the engine free of a keyboard
    // convention it has no business knowing.
    if case .key(let key, let modifiers) = input, modifiers.shift {
      switch key {
      case .pageUp: scroll(.pageUp); return
      case .pageDown: scroll(.pageDown); return
      case .home: scroll(.oldest); return
      case .end: scroll(.live); return
      default: break
      }
    }
    // A key typed while the shell is showing something else's history has
    // to land on the live prompt. The wait is only that restoration;
    // everything else is written straight through, and keys keep their order.
    let restore = attachments.contains(where: \.attachment.shellInputWaits)
    if !restore, keyQueue == nil {
      try? session?.send(input)
      return
    }
    keySerial += 1
    let serial = keySerial
    let pending = attachments
    let session = session
    let previous = keyQueue
    keyQueue = Task { @MainActor [weak self] in
      await previous?.value
      if restore {
        for item in pending where item.attachment.shellInputWaits {
          await item.attachment.restoreShellForInput()
        }
      }
      try? session?.send(input)
      if self?.keySerial == serial { self?.keyQueue = nil }
    }
  }

  /// What the text at a cell names, if anything. Asked when a person points.
  func link(atRow row: UInt16, column: UInt16) -> TerminalLink? {
    session?.link(atRow: row, column: column)
  }

  /// The directory the shell last reported, if it reports one.
  var workingDirectory: String? { session?.workingDirectory }
  var terminalName: String? { session?.terminalName ?? shellTTY }

  /// Moves the viewport over the scrollback.
  ///
  /// The repaint loop wakes on the same change and publishes on the next
  /// refresh. Pulling a second copy here made a drag cost two grids per line.
  /// A wheel can belong to whatever is standing on this shell instead: a
  /// full-screen program keeps its own history, and the alternate screen
  /// here has none.
  func scroll(_ to: ScrollTo) {
    if case .lines(let lines) = to {
      let fullScreen = frame?.alternateScreen == true
      if attachments.contains(where: { $0.attachment.scrollShell(lines, fullScreen: fullScreen) }) {
        return
      }
    }
    session?.scroll(to)
  }

  /// A wheel the program asked to hear. `true` means an attachment took the
  /// lines, so the view does not also report them as pointer events.
  func claimWheel(_ lines: Int32, column: UInt16, row: UInt16) -> Bool {
    attachments.contains { $0.attachment.claimWheel(lines, column: column, row: row) }
  }

  /// Moves this shell's own history, without offering the lines to a plugin
  /// again. Positive goes back.
  func scrollOwnHistory(by lines: Int32) {
    guard lines != 0 else { return }
    session?.scroll(.lines(lines))
  }

  /// Tells the far side what this window draws with.
  ///
  /// The colours a program paints itself in are its own; what it asks first
  /// is whether the terminal is light or dark, and this is the answer. Sent
  /// again whenever the appearance changes, because it is the same question.
  func use(palette: TerminalPalette) {
    guard palette != self.palette else { return }
    self.palette = palette
    try? session?.setPalette(palette)
  }

  func resize(columns: UInt16, rows: UInt16) {
    guard columns > 0, rows > 0 else { return }
    // The shell leaves the tree while a plugin stands in for it, and the
    // view reports the size it collapses through on the way out. Applying
    // that shrinks the pty, and a client already running on it then pins
    // the window to a corner of this one.
    guard shown == nil else { return }
    sized = true
    identifyShellTTY()
    guard columns != self.columns || rows != self.rows else { return }
    self.columns = columns
    self.rows = rows
    resizeEpoch += 1
    try? session?.resize(columns: columns, rows: rows)
    // The engine has already reflowed. Draw that screen now: waiting for
    // the next byte left the old grid up until something else was printed.
    guard publishesFrames, let session else { return }
    frame = session.frame()
    dirtyRows = nil
  }

  /// Names this shell's far-side tty, when the session itself has none.
  /// One search at a time: a resize while the previous listing is in flight
  /// drops that listing, so an 80×24 answer cannot arrive after the real one.
  private func identifyShellTTY() {
    guard shellTTY == nil, session?.terminalName == nil, let connection = session?.connection
    else { return }
    let columns = self.columns
    let rows = self.rows
    let matchSize = sized
    ttySearch?.cancel()
    ttySearch = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard let self, !Task.isCancelled else { return }
      let found = await ShellTTY.find(
        on: connection, columns: columns, rows: rows, matchSize: matchSize)
      guard !Task.isCancelled, self.shellTTY == nil else { return }
      self.shellTTY = found
    }
  }

  func connectionReady() async throws -> RemoteConnection {
    if let connection { return connection }
    switch stage {
    case .failed(let reason):
      throw NSError(domain: "Tether", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    case .ended:
      throw CancellationError()
    default:
      break
    }
    if closed { throw CancellationError() }
    return try await withCheckedThrowingContinuation { ready.append($0) }
  }

  func close() {
    closed = true
    problem = nil
    passwordOffer = nil
    dialTask?.cancel()
    ttySearch?.cancel()
    ready.forEach { $0.resume(throwing: CancellationError()) }
    ready.removeAll()
    // A question on screen is withdrawn, and the handshake waiting on it is
    // told no — rather than left suspended for the life of the process,
    // holding its connection open.
    authentication?.cancel()

    pump?.cancel()
    attachments.forEach { $0.attachment.close() }
    attachments.removeAll()
    session?.close()
    session = nil
  }

  /// Whether a plugin's accessory has anything to open here: a lease to
  /// attach with, or an attachment already made — which, after a reconnect,
  /// holds a lease this tab's own shell no longer does.
  func canOpen(_ pluginID: String) -> Bool {
    connection != nil || attachment(for: pluginID) != nil
  }

  func attachment(for pluginID: String) -> (any TabAttachment)? {
    attachments.first { $0.pluginID == pluginID }?.attachment
  }

  func attach(_ attachment: any TabAttachment, for pluginID: String) {
    precondition(self.attachment(for: pluginID) == nil, "One attachment per plugin per tab")
    attachments.append(TabAttachmentEntry(pluginID: pluginID, attachment: attachment))
  }

  /// Closes and forgets one plugin's attachment, as when it is turned off.
  func detach(_ pluginID: String) {
    attachments.filter { $0.pluginID == pluginID }.forEach { $0.attachment.close() }
    attachments.removeAll { $0.pluginID == pluginID }
  }

  // MARK: - Questions

  /// Puts a handshake's question to the person, and waits.
  fileprivate func ask(_ question: HandshakeQuestion, shown: @escaping @MainActor () -> Void) async -> [String]? {
    guard !closed else { return nil }
    stage = .asking
    // Back to `.connecting`: the handshake is still open, now waiting on the
    // answer just given rather than on the person.
    defer { if case .asking = stage { stage = .connecting } }
    let reply = await DialogPresenter.ask(question.dialog, shown: shown)
    // Nowhere to show it, or taken away by the platform: not the person's
    // no, and not to be closed as if it were.
    if reply == nil, !Task.isCancelled { authentication?.questionWentUnanswered() }
    return question.answers(from: reply)
  }
}

func message(for error: Error) -> String {
  // `TetherError` carries its own sentence via `LocalizedError`. Anything
  // else still has to read as a sentence rather than as an empty box.
  let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
  return text.isEmpty ? "\(error)" : text
}
