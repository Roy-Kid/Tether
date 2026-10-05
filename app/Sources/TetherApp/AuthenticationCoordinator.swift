import Foundation
import Tether

/// Authentication belongs to a connection attempt, independently of its terminal.
@MainActor
final class AuthenticationCoordinator {
  let host: Host
  private let known: KnownHosts
  private let credentials: DeviceCredentialStore
  /// Puts a question to a person, and says when it is on screen. `nil` is a no.
  typealias Ask = @MainActor (HandshakeQuestion, _ shown: @escaping @MainActor () -> Void) async -> [String]?
  private let ask: Ask
  private var password: String
  private var verified = false
  private var fingerprint: String?
  private var authorized = false
  private var cancelled = false
  /// Why this side said no, when it did. The server only hears the no, and
  /// the error that comes back up names what it saw rather than the reason.
  private(set) var refusal: Error?
  /// How long a question waits for a person before the login stops waiting.
  private let answerTimeout: Duration
  /// The server asked the one-time code this profile routes to a secret.
  private var otpRequested = false
  /// Why the saved code could not answer, told on the dialog that asks instead.
  private var savedCodeProblem: String?
  /// The account password the person typed during this login, if they did.
  /// Read once the login has worked — it is the one worth keeping — and
  /// gone with everything else when the attempt ends.
  private(set) var typedPassword: String?
  /// Whether the password handed in took part in the login: it answered the
  /// server's password prompt, or there was nothing else to log in with.
  private(set) var passwordProven = false
  private var savedPasswordAnswered = false
  private var keysOffered = false
  private var history = ChallengeHistory()
  /// The question on screen, withdrawn when this attempt is.
  private var asking: Task<[String]?, Never>?
  /// Counts from when the question is shown, not asked: another dialog may
  /// be in front of it for a while, and waiting there is not ignoring it.
  private var deadline: Task<Void, Never>?
  private var expired = false

  init(host: Host, password: String, known: KnownHosts,
    credentials: DeviceCredentialStore = DeviceCredentialStore(), answerTimeout: Duration = .seconds(90),
    ask: @escaping Ask) {
    self.host = host; self.password = password; self.known = known
    self.credentials = credentials; self.answerTimeout = answerTimeout; self.ask = ask
  }

  func cancel() {
    cancelled = true; password = ""; typedPassword = nil; verified = false; authorized = false
    asking?.cancel()
  }

  func connect(columns: UInt16, rows: UInt16, history: SessionHistory? = nil) async throws -> TerminalSession {
    defer { password = "" }
    if let issue = host.connectionProblem ?? host.routeProblem { throw IdentityError.storage(issue) }
    if let profile = host.profile { try profile.validate() }
    var offered: [Credential] = []
    // What each key is called, by its place in `offered`: the SDK names a
    // key it could not use by position, and a person knows it by its file.
    var keyNames: [Int: String] = [:]
    func offer(_ pem: String, named name: String) {
      keyNames[offered.count] = name
      offered.append(.privateKey(pem: pem, unlock: Unlock(owner: self, name: name)))
    }
    // This device's key, whatever the other devices use. No default key
    // discovery for a managed identity: its key is the one bound here.
    if let id = host.credentialSecretID {
      offer(try credentials.read(id), named: "\(host.label) key")
    } else {
      let paths = !host.isManaged || host.usesDefaultKeys
        ? identityFiles(for: host) : host.keyPath.map { [$0] } ?? []
      for path in paths {
        do { offer(try String(contentsOfFile: expandingTilde(path), encoding: .utf8), named: keyName(path)) }
        catch { if host.keyPath != nil { throw IdentityError.missingCredential } }
      }
    }
    keysOffered = !offered.isEmpty
    // After the keys, so a key that works is used first; still offered, so a
    // server that wants a password gets the one the person gave.
    if !password.isEmpty { offered.append(.password(password)) }
    offered.append(.interactive(Interactive(owner: self)))
    let session: TerminalSession
    do {
      session = try await TerminalSession.connect(to: Destination(host: host.hostname, port: host.port,
        user: host.username, columns: columns, rows: rows, history: history), trusting: Verification(owner: self), offering: offered)
    } catch {
      throw refusal ?? namingSkippedKeys(error, keyNames)
    }
    passwordProven = savedPasswordAnswered || !keysOffered
    if host.profile?.authentication.otp != nil && !otpRequested {
      session.close()
      throw IdentityError.storage("The server did not request the MFA factor required by this profile.")
    }
    guard !cancelled, !Task.isCancelled else { session.close(); throw CancellationError() }
    return session
  }

  func verify(_ identity: HostIdentity) async -> Bool {
    guard !cancelled, identity.host == host.hostname, identity.port == host.port else { return false }
    switch known.question(for: identity) {
    case .changed(let recorded)?:
      // A changed server key never silently replaces an existing pin. Removing
      // the old pin is an explicit Security settings operation — or, for one
      // system ssh recorded, `ssh-keygen -R`.
      refuse(recorded.source == nil ? IdentityError.hostKeyChanged : IdentityError.systemHostKeyChanged)
      return false
    case .unknown?:
      guard await question(.trust(identity)) != nil, !cancelled else { return false }
      known.remember(identity)
    case nil:
      break
    }
    fingerprint = identity.fingerprint
    verified = true
    if let profile = host.profile, profile.authentication.confirmation != .automatic {
      let approval = HandshakeQuestion.confirmation(
        title: "Authenticate to \(host.label)", detail: "\(host.address)\n\(identity.fingerprint)")
      guard await question(approval) != nil, !cancelled else { return false }
    }
    authorized = true
    return true
  }

  /// One keyboard-interactive round. What this device can answer, it does;
  /// the rest goes to the person in one dialog. An empty reply declines.
  func answer(instruction: String, prompts: [AuthPrompt]) async -> [String] {
    guard verified, authorized, !cancelled, !Task.isCancelled, !prompts.isEmpty else { return [] }
    let titles = prompts.map(promptDialogTitle)
    history.begin(titles)
    var answers = Array(repeating: "", count: prompts.count)
    var round: [String: ChallengeHistory.Source] = [:]
    var open: [Int] = []
    for index in prompts.indices {
      if history.maySave(titles[index]),
        let saved = await savedAnswer(for: prompts[index], alone: prompts.count == 1)
      {
        answers[index] = saved
        round[titles[index]] = .saved
        if isAccountPasswordPrompt(prompts[index]) { savedPasswordAnswered = true }
      } else {
        open.append(index)
      }
    }
    guard !cancelled, !Task.isCancelled else { return [] }
    if !open.isEmpty {
      let notice = history.notice(for: open.map { titles[$0] }) ?? savedCodeProblem
      savedCodeProblem = nil
      let asked = HandshakeQuestion.prompts(open.map { prompts[$0] }, instruction: instruction, notice: notice)
      guard let typed = await question(asked), typed.count == open.count, !cancelled else { return [] }
      for (index, value) in zip(open, typed) {
        answers[index] = value
        round[titles[index]] = .person
        if isAccountPasswordPrompt(prompts[index]), !value.isEmpty { typedPassword = value }
      }
    }
    history.record(round)
    return answers
  }

  /// What this device answers without asking: the account password the
  /// person already gave, or the one-time code a profile routes to a stored
  /// secret or an approving device — for the exact prompt it names, and only
  /// once the host is verified and the login approved.
  private func savedAnswer(for prompt: AuthPrompt, alone: Bool) async -> String? {
    if !password.isEmpty, isAccountPasswordPrompt(prompt) { return password }
    guard alone, !prompt.echo, let profile = host.profile, profile.authentication.otp != nil,
      prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        == profile.authentication.otpPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    otpRequested = true
    // When nothing on this device can answer it, the person can — and is
    // told why they are being asked.
    do {
      if let recipient = profile.authentication.remoteApprovalDevice,
        recipient != ContinuityService.active[host.accountScope]?.local?.id {
        guard let center = ContinuityService.active[host.accountScope], let fingerprint else {
          savedCodeProblem = "The approving device is not reachable."
          return nil
        }
        return try await center.requestOTP(host: host, fingerprint: fingerprint)
      }
      guard let id = host.otpSecretID else {
        savedCodeProblem = "No code is saved on this device."
        return nil
      }
      let otp = try JSONDecoder().decode(TOTP.self, from: Data(credentials.read(id).utf8))
      return try otp.code()
    } catch {
      savedCodeProblem = "The saved code could not be used. \(message(for: error))"
      return nil
    }
  }

  /// One key's passphrase. Asked only once the server has said it would
  /// take the key, where the key's format lets it be asked first — and only
  /// after the host is verified and the login approved, like every other
  /// question a login asks. `nil` is a no, and ends the login as one.
  func passphrase(forKey name: String, _ key: LockedKey, attempt: Int) async -> String? {
    guard verified, authorized, !cancelled, !Task.isCancelled else { return nil }
    let notice = attempt > 1 ? "The passphrase was not accepted." : nil
    let asked = HandshakeQuestion.passphrase(key: name, fingerprint: key.fingerprint, notice: notice)
    guard let typed = await question(asked), let passphrase = typed.first, !cancelled else { return nil }
    return passphrase
  }

  /// Asks, for as long as a person has to answer. `nil` is a no: declined,
  /// unanswered in time, or withdrawn because this attempt was.
  private func question(_ question: HandshakeQuestion) async -> [String]? {
    guard !cancelled, !Task.isCancelled else { return nil }
    let ask = self.ask
    expired = false
    let pending = Task { [weak self] in
      await ask(question) { [weak self] in self?.startDeadline() }
    }
    asking = pending
    defer {
      deadline?.cancel()
      deadline = nil
      if asking == pending { asking = nil }
    }
    let reply = await withTaskCancellationHandler {
      await pending.value
    } onCancel: {
      pending.cancel()
    }
    if reply == nil {
      // Unanswered in time is a failure to report; a person's own no is
      // a decision, and ends the attempt without one.
      if expired {
        refuse(IdentityError.unanswered)
      } else if !cancelled, !Task.isCancelled {
        refuse(CancellationError())
      }
    }
    return cancelled ? nil : reply
  }

  private func startDeadline() {
    deadline?.cancel()
    let timeout = answerTimeout
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard let self else { return }
      expired = true
      asking?.cancel()
    }
  }

  /// A question that never reached the person — nowhere to show it, or
  /// taken away by the platform. A failure to report, not their no.
  func questionWentUnanswered() {
    refuse(IdentityError.unshown)
  }

  /// The first reason is the one that counts.
  private func refuse(_ reason: Error) {
    if refusal == nil { refusal = reason }
  }

  private struct Verification: HostTrust {
    let owner: AuthenticationCoordinator
    func trusts(_ host: HostIdentity) async -> Bool { await owner.verify(host) }
  }
  private struct Unlock: KeyUnlocker {
    let owner: AuthenticationCoordinator
    let name: String
    func passphrase(for key: LockedKey, attempt: Int) async -> String? {
      await owner.passphrase(forKey: name, key, attempt: attempt)
    }
  }
  private struct Interactive: AuthPrompter {
    let owner: AuthenticationCoordinator
    func answer(instruction: String, prompts: [AuthPrompt]) async -> [String] {
      await owner.answer(instruction: instruction, prompts: prompts)
    }
  }
}

/// What a person calls a key file: its name, as `ls ~/.ssh` shows it.
func keyName(_ path: String) -> String {
  let name = (path as NSString).lastPathComponent
  return name.isEmpty ? path : name
}

/// A refused login that left keys out says which, by the names this device
/// knows them by. Anything else passes through untouched — a
/// `TetherError` stays one, because what it is decides what the person is
/// offered next.
func namingSkippedKeys(_ error: Error, _ keyNames: [Int: String]) -> Error {
  guard case TetherError.authenticationFailed(let remaining, let skipped) = error, !skipped.isEmpty else {
    return error
  }
  let named = skipped.map { key in
    var key = key
    key.name = key.name ?? keyNames[key.position]
    return key
  }
  return TetherError.authenticationFailed(remaining: remaining, skipped: named)
}
