import Foundation
import Tether

/// Authentication belongs to a connection attempt, independently of its terminal.
@MainActor
final class AuthenticationCoordinator {
  let host: Host
  private let known: KnownHosts
  private let credentials: DeviceCredentialStore
  private let ask: (Question.Kind) -> Void
  private let answered: () -> Void
  private var password: String
  private var verified = false
  private var fingerprint: String?
  private var authorized = false
  private var cancelled = false
  private var otpUsed = false
  private var cancelQuestion: (() -> Void)?

  init(host: Host, password: String, known: KnownHosts,
    credentials: DeviceCredentialStore = DeviceCredentialStore(),
    ask: @escaping (Question.Kind) -> Void, answered: @escaping () -> Void) {
    self.host = host; self.password = password; self.known = known
    self.credentials = credentials; self.ask = ask; self.answered = answered
  }

  func cancel() { cancelled = true; password = ""; verified = false; authorized = false; cancelQuestion?() }

  func connect(columns: UInt16, rows: UInt16) async throws -> TerminalSession {
    defer { password = "" }
    if let issue = host.connectionProblem { throw IdentityError.storage(issue) }
    if let profile = host.profile { try profile.validate() }
    var offered: [Credential] = []
    // No default key discovery for a managed identity.
    if let id = host.credentialSecretID, host.profile?.authentication.primary.purpose == .ssh {
      offered.append(.privateKey(pem: try credentials.read(id)))
    } else {
      let paths = host.isManaged ? host.keyPath.map { [$0] } ?? [] : identityFiles(for: host)
      for path in paths {
        do { offered.append(.privateKey(pem: try String(contentsOfFile: expandingTilde(path), encoding: .utf8))) }
        catch { if host.keyPath != nil { throw IdentityError.missingCredential } }
      }
    }
    if host.profile?.authentication.primary.purpose == .ssh && offered.isEmpty { throw IdentityError.missingCredential }
    if offered.isEmpty, !password.isEmpty { offered.append(.password(password)) }
    offered.append(.interactive(Interactive(owner: self)))
    let session = try await TerminalSession.connect(to: Destination(host: host.hostname, port: host.port,
      user: host.username, columns: columns, rows: rows), trusting: Verification(owner: self), offering: offered)
    if host.profile?.authentication.otp != nil && !otpUsed {
      session.close()
      throw IdentityError.storage("The server did not request the MFA factor required by this profile.")
    }
    guard !cancelled, !Task.isCancelled else { session.close(); throw CancellationError() }
    return session
  }

  func verify(_ identity: HostIdentity) async -> Bool {
    guard !cancelled, identity.host == host.hostname, identity.port == host.port else { return false }
    if let why = known.question(for: identity) {
      // A changed server key never silently replaces an existing pin. Removing
      // the old pin is an explicit Security settings operation.
      if case .changed = why { return false }
      let accepted = await question(default: false) { answer in
        .trust(host: identity, why: why, answer: answer)
      }
      answered()
      guard accepted, !cancelled else { return false }
      known.remember(identity)
    }
    fingerprint = identity.fingerprint
    verified = true
    if let profile = host.profile, profile.authentication.confirmation != .automatic {
      let accepted = await question(default: false) { answer in
        .confirmation(title: "Authenticate to \(host.label)",
          detail: "\(host.address)\n\(identity.fingerprint)", answer: answer)
      }
      answered()
      guard accepted, !cancelled else { return false }
    }
    authorized = true
    return true
  }

  func answer(instruction: String, prompts: [AuthPrompt]) async -> [String] {
    guard verified, authorized, !cancelled, !Task.isCancelled else { return [] }
    if let profile = host.profile, profile.authentication.otp != nil,
      prompts.count == 1, !prompts[0].echo,
      prompts[0].text.trimmingCharacters(in: .whitespacesAndNewlines) == profile.authentication.otpPrompt {
      guard !otpUsed else { return [] }
      otpUsed = true
      do {
        if let recipient = profile.authentication.remoteApprovalDevice,
          recipient != ContinuityService.active[host.accountScope]?.local?.id {
          guard let center = ContinuityService.active[host.accountScope], let fingerprint else { return [] }
          let code = try await center.requestOTP(host: host, fingerprint: fingerprint)
          guard !cancelled, !Task.isCancelled else { return [] }
          return [code]
        }
        guard let id = host.otpSecretID else { throw IdentityError.missingCredential }
        let otp = try JSONDecoder().decode(TOTP.self, from: Data(credentials.read(id).utf8))
        return [try otp.code()]
      } catch { return [] }
    }
    var answers = Array(repeating: "", count: prompts.count)
    var indices: [Int] = []
    for (index, prompt) in prompts.enumerated() {
      if !password.isEmpty, isAccountPasswordPrompt(prompt) { answers[index] = password }
      else { indices.append(index) }
    }
    if !indices.isEmpty {
      let requested = indices.map { prompts[$0] }
      let input: [String] = await question(default: []) { answer in
        .prompts(instruction: instruction, prompts: requested, answer: answer)
      }
      answered()
      guard !cancelled, input.count == indices.count else { return [] }
      for (index, value) in zip(indices, input) { answers[index] = value }
    }
    return answers
  }

  private func question<Value: Sendable>(default fallback: Value,
    make: (@escaping (Value) -> Void) -> Question.Kind) async -> Value {
    guard !cancelled, !Task.isCancelled else { return fallback }
    let once = AuthenticationAnswer<Value>()
    let timeout = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(90)) } catch { return }
      once.resume(fallback)
    }
    defer { timeout.cancel(); cancelQuestion = nil }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        once.continuation = continuation
        cancelQuestion = { once.resume(fallback) }
        ask(make { once.resume($0) })
      }
    } onCancel: {
      Task { @MainActor in once.resume(fallback) }
    }
  }

  private struct Verification: HostTrust {
    let owner: AuthenticationCoordinator
    func trusts(_ host: HostIdentity) async -> Bool { await owner.verify(host) }
  }
  private struct Interactive: AuthPrompter {
    let owner: AuthenticationCoordinator
    func answer(instruction: String, prompts: [AuthPrompt]) async -> [String] {
      await owner.answer(instruction: instruction, prompts: prompts)
    }
  }
}

@MainActor
private final class AuthenticationAnswer<Value: Sendable> {
  var continuation: CheckedContinuation<Value, Never>?
  func resume(_ value: Value) {
    let pending = continuation
    continuation = nil
    pending?.resume(returning: value)
  }
}
