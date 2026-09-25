import Foundation
import Observation
import Tether
import TetherPluginKit

/// What a tab is currently doing.
enum Stage {
  case connecting
  /// The handshake is waiting on a person: a host to trust, or answers to
  /// give. The connection is genuinely blocked until it is resolved.
  case asking(Question)
  case connected
  case failed(String)
  case ended(String?)
}

/// Something the session needs a person to decide.
///
/// Data with a continuation rather than a callback into the view: both
/// questions arrive on a background task and must be answered from the UI.
struct Question: Identifiable {
  let id = UUID()
  let kind: Kind

  enum Kind {
    case confirmation(title: String, detail: String, answer: (Bool) -> Void)
    case trust(host: HostIdentity, why: TrustQuestion, answer: (Bool) -> Void)
    case prompts(instruction: String, prompts: [AuthPrompt], answer: ([String]) -> Void)
  }

  /// Answers in the negative, for when there is no longer anyone to ask.
  ///
  /// The handshake is parked on a continuation until this is called. A tab
  /// closed mid-question would otherwise leave that task suspended for the
  /// life of the process, holding its connection open — a leak with no
  /// symptom until there are enough of them.
  func decline() {
    switch kind {
    case .confirmation(_, _, let answer): answer(false)
    case .trust(_, _, let answer): answer(false)
    case .prompts(_, _, let answer): answer([])
    }
  }
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
  let host: Host
  /// Stable work-position name (`Terminal 1`), not the remote title.
  var name: String

  private(set) var stage: Stage = .connecting
  private(set) var frame: ScreenFrame?
  private(set) var remoteTitle: String = ""

  /// Primary tab label. Identity is `id`, never this string.
  var title: String { name }

  /// What the tab shows next to the name: whatever stands in for the shell
  /// says what it is, and the shell itself says nothing. The remote OSC
  /// title stays in the terminal; it is not the tab's identity.
  var subtitle: String { shown?.subtitle ?? "" }

  /// What tab plugins keep on this tab, in the order they first opened here.
  private(set) var attachments: [TabAttachmentEntry] = []

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
  /// What the window draws with, held so a session that opens later is told
  /// the same thing the one before it was.
  private var palette: TerminalPalette?

  private let known: KnownHosts
  /// Held only for the handshake, so a keyboard-interactive "Password:"
  /// round can be answered with what the person already typed. Cleared
  /// once the session is up or the attempt fails.
  fileprivate var offeredPassword: String = ""

  init(host: Host, password: String, known: KnownHosts, name: String) {
    self.host = host
    self.known = known
    self.name = name
    self.offeredPassword = password
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
    let coordinator = AuthenticationCoordinator(host: host, password: password, known: known,
      ask: { [weak self] kind in
        guard let self else { Question(kind: kind).decline(); return }
        self.ask(kind)
      }, answered: { [weak self] in self?.answered() })
    authentication = coordinator
    defer { coordinator.cancel(); authentication = nil; offeredPassword = "" }
    do { adopt(try await coordinator.connect(columns: columns, rows: rows)) }
    catch { fail(error) }
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
    offeredPassword = ""
    // Before the first byte where possible: a program can ask what the
    // background is in its first breath, and an unanswered question is
    // answered by the convention that a terminal is dark.
    try? session.setPalette(palette)
    if let connection = session.connection {
      ready.forEach { $0.resume(returning: connection) }
      ready.removeAll()
    }
    stage = .connected
    frame = session.frame()
    startPumping(session)
  }

  private func fail(_ error: Error) {
    offeredPassword = ""
    stage = .failed(message(for: error))
    ready.forEach { $0.resume(throwing: error) }
    ready.removeAll()
  }

  /// Repaints when the screen changes, and not otherwise.
  ///
  /// No timer: the session wakes this loop on the first byte, and costs
  /// nothing while the screen is still.
  private func startPumping(_ session: TerminalSession) {
    pump = Task { [weak self] in
      while await session.awaitChange() {
        guard let self, !Task.isCancelled else { return }
        await MainActor.run {
          let frame = session.frame()
          self.frame = frame
          self.remoteTitle = frame.title
        }
      }

      // One last repaint. The final frame is announced before the
      // ending is, so stopping here would leave a program's last line
      // undrawn.
      guard let self else { return }
      await MainActor.run {
        self.frame = session.frame()
        self.finish(session.ending())
      }
    }
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
    try? session?.send(input)
  }

  /// What the text at a cell names, if anything. Asked when a person points.
  func link(atRow row: UInt16, column: UInt16) -> TerminalLink? {
    session?.link(atRow: row, column: column)
  }

  /// The directory the shell last reported, if it reports one.
  var workingDirectory: String? { session?.workingDirectory }
  var terminalName: String? { session?.terminalName }

  /// Moves the viewport over the scrollback.
  func scroll(_ to: ScrollTo) {
    session?.scroll(to)
    // The frame is pulled rather than waited for: the repaint loop wakes on
    // the change too, but a scroll should not lag a frame behind the finger
    // that asked for it.
    if let session { frame = session.frame() }
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
    guard columns != self.columns || rows != self.rows else { return }
    self.columns = columns
    self.rows = rows
    try? session?.resize(columns: columns, rows: rows)
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
    dialTask?.cancel()
    ready.forEach { $0.resume(throwing: CancellationError()) }
    ready.removeAll()
    // Anyone still waiting on an answer is told no, before the state that
    // holds their continuation goes away.
    authentication?.cancel()
    if case .asking(let question) = stage { question.decline() }

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

  fileprivate func ask(_ kind: Question.Kind) {
    let question = Question(kind: kind)
    guard !closed else {
      question.decline()
      return
    }
    stage = .asking(question)
    HandshakeAlert.present(question)
  }

  /// Back to `.connecting`: the handshake is still open, now waiting on the
  /// answer that was just given rather than on the person.
  fileprivate func answered() {
    if case .asking = stage { stage = .connecting }
  }

  fileprivate var knownHosts: KnownHosts { known }
}

func isAccountPasswordPrompt(_ prompt: AuthPrompt) -> Bool {
  guard !prompt.echo else { return false }
  let folded = prompt.text.lowercased()
  if folded.contains("one-time") || folded.contains("verification")
    || folded.contains("otp") || folded.contains("token")
    || folded.contains("passcode") || folded.contains("authenticator")
    || folded.contains("challenge")
  {
    return false
  }
  let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
    .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed == "password" || trimmed.hasPrefix("password ")
    || trimmed.hasSuffix(" password")
}

/// The server's prompt, without a trailing colon, for a dialog title.
func promptDialogTitle(_ prompt: AuthPrompt) -> String {
  var text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
  while text.hasSuffix(":") || text.hasSuffix("：") {
    text.removeLast()
  }
  text = text.trimmingCharacters(in: .whitespaces)
  return text.isEmpty ? "Continue" : text
}

func message(for error: Error) -> String {
  // `TetherError` carries its own sentence via `LocalizedError`. Anything
  // else still has to read as a sentence rather than as an empty box.
  let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
  return text.isEmpty ? "\(error)" : text
}
