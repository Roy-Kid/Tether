import Foundation
import Observation
import Tether

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
    case .trust(_, _, let answer): answer(false)
    case .prompts(_, _, let answer): answer([])
    }
  }
}

/// One open session — one tab.
@MainActor
@Observable
final class SessionTab: Identifiable {
  let id = UUID()
  let host: Host

  private(set) var stage: Stage = .connecting
  private(set) var frame: ScreenFrame?
  private(set) var remoteTitle: String = ""

  /// What the tab shows on its chip. The remote title when the far side
  /// set one, because that is how a person tells two shells on the same
  /// host apart; the host's own label otherwise.
  var title: String {
    remoteTitle.isEmpty ? (host.label.isEmpty ? host.hostname : host.label) : remoteTitle
  }

  var isLive: Bool {
    if case .connected = stage { return true }
    return false
  }

  private var session: TerminalSession?
  var connection: RemoteConnection? { session?.connection }
  private var closed = false
  private var ready: [CheckedContinuation<RemoteConnection, Error>] = []
  private var pump: Task<Void, Never>?
  private var dialTask: Task<Void, Never>?

  private var columns: UInt16 = 80
  private var rows: UInt16 = 24

  private let known: KnownHosts

  init(host: Host, password: String, known: KnownHosts) {
    self.host = host
    self.known = known
    dialTask = Task { await dial(password) }
  }

  /// Reads the key, if this host has one.
  ///
  /// At connect time rather than at save time, so a key that was moved or
  /// had its permissions tightened is noticed now, when there is a person
  /// to tell.
  private func keyCredential() -> Credential? {
    guard let path = host.keyPath, !path.isEmpty else { return nil }
    guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return .privateKey(pem: pem, passphrase: nil)
  }

  private func dial(_ password: String) async {
    let destination = Destination(
      host: host.hostname,
      port: host.port,
      user: host.username,
      columns: columns,
      rows: rows)

    if let path = host.keyPath, !path.isEmpty, keyCredential() == nil {
      let failure = NSError(
        domain: "Tether", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not read the key at \(path)."])
      stage = .failed(failure.localizedDescription)
      ready.forEach { $0.resume(throwing: failure) }
      ready.removeAll()
      return
    }

    do {
      // Key first, then password, then interactive. The order is the
      // offer order, and each is tried only if the server is still
      // asking — which is also how "a key, then a one-time code" works
      // without any special case for it.
      var credentials: [Credential] = []
      if let key = keyCredential() { credentials.append(key) }
      if !password.isEmpty { credentials.append(.password(password)) }
      credentials.append(.interactive(Prompter(tab: self)))

      let session = try await TerminalSession.connect(
        to: destination,
        trusting: Trust(tab: self),
        offering: credentials)

      guard !closed else {
        session.close()
        return
      }
      self.session = session
      if let connection = session.connection {
        ready.forEach { $0.resume(returning: connection) }
        ready.removeAll()
      }
      stage = .connected
      frame = session.frame()
      startPumping(session)
    } catch {
      stage = .failed(describe(error))
      ready.forEach { $0.resume(throwing: error) }
      ready.removeAll()
    }
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

  /// Moves the viewport over the scrollback.
  func scroll(_ to: ScrollTo) {
    session?.scroll(to)
    // The frame is pulled rather than waited for: the repaint loop wakes on
    // the change too, but a scroll should not lag a frame behind the finger
    // that asked for it.
    if let session { frame = session.frame() }
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
    if case .failed(let reason) = stage {
      throw NSError(domain: "Tether", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
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
    if case .asking(let question) = stage { question.decline() }

    pump?.cancel()
    session?.close()
    session = nil
  }

  // MARK: - Questions

  fileprivate func ask(_ kind: Question.Kind) {
    let question = Question(kind: kind)
    guard !closed else {
      question.decline()
      return
    }
    stage = .asking(question)
  }

  /// Back to `.connecting`: the handshake is still open, now waiting on the
  /// answer that was just given rather than on the person.
  fileprivate func answered() {
    if case .asking = stage { stage = .connecting }
  }

  fileprivate var knownHosts: KnownHosts { known }
}

// MARK: - Bridges to the SDK's callbacks

private struct Trust: HostTrust {
  let tab: SessionTab

  func trusts(_ host: HostIdentity) async -> Bool {
    // Nobody is asked about a key they already vouched for. Asking again
    // trains a person to accept without reading, which is exactly what the
    // prompt exists to prevent.
    guard let why = await tab.knownHosts.question(for: host) else { return true }

    let accepted = await withCheckedContinuation { continuation in
      Task { @MainActor in
        tab.ask(.trust(host: host, why: why) { continuation.resume(returning: $0) })
      }
    }

    if accepted { await tab.knownHosts.remember(host) }
    await tab.answered()
    return accepted
  }
}

private struct Prompter: AuthPrompter {
  let tab: SessionTab

  func answer(instruction: String, prompts: [AuthPrompt]) async -> [String] {
    let answers = await withCheckedContinuation { continuation in
      Task { @MainActor in
        tab.ask(
          .prompts(instruction: instruction, prompts: prompts) {
            continuation.resume(returning: $0)
          })
      }
    }
    await tab.answered()
    return answers
  }
}

private func describe(_ error: Error) -> String {
  guard let error = error as? TetherError else { return "\(error)" }
  return switch error {
  case .cancelled: "Cancelled."
  case .timedOut(let millis): "Timed out after \(millis)ms."
  case .unreachable(_, let cause): "Could not reach the host. \(cause)"
  case .hostRejected: "The host key was not trusted."
  case .authenticationFailed(let remaining):
    remaining.isEmpty
      ? "Authentication failed."
      : "Authentication failed. The server accepts: \(remaining.joined(separator: ", "))."
  case .moreFactorsNeeded(let remaining):
    "Another factor is needed: \(remaining.joined(separator: ", "))."
  case .nothingToOffer: "No credentials were offered."
  case .shellRefused(let cause): "The server refused to open a shell. \(cause)"
  case .disconnected(let cause): "The connection was lost. \(cause)"
  case .sessionEnded: "The session has ended."
  case .protocolFailure(let cause): "Protocol failure. \(cause)"
  }
}

