import Foundation
import Tether
import TetherUI
import Testing

@testable import TetherApp

import struct TetherApp.Host

/// A person at the other end of the handshake's questions, answering from a
/// script and remembering what they were asked.
@MainActor
private final class Person {
  var asked: [HandshakeQuestion] = []
  var replies: [[String]?]

  init(_ replies: [[String]?] = []) {
    self.replies = replies
  }

  func answer(_ question: HandshakeQuestion, shown: @MainActor () -> Void) async -> [String]? {
    shown()
    asked.append(question)
    switch question {
    case .trust, .confirmation: return []
    case .prompts, .passphrase: return replies.isEmpty ? nil : replies.removeFirst()
    }
  }

  var notices: [String?] {
    asked.compactMap { if case .prompts(_, _, let notice) = $0 { notice } else { nil } }
  }

  var prompted: [String] {
    asked.compactMap { if case .prompts(let prompts, _, _) = $0 { prompts.first?.text } else { nil } }
  }
}

private let password = AuthPrompt(text: "Password: ", echo: false)
private let code = AuthPrompt(text: "Verification code: ", echo: false)
private let key = HostIdentity(host: "login.example.org", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:fixture")

/// Arrhenius, as a phone reaches it: a managed host with a saved password,
/// approved on every login, whose server asks `Password:` and then
/// `Verification code:` over keyboard-interactive.
@MainActor
private func arrhenius(savedPassword: String, person: Person) async -> (AuthenticationCoordinator, URL) {
  let path = temporaryFile("known")
  let identity = AccountIdentity(name: "Arrhenius")
  let profile = HostProfile(
    id: UUID(), label: "Arrhenius", hostname: key.host, port: 22, username: "ada",
    authentication: AuthenticationProfile(
      identity: identity, primary: CredentialDescriptor(identityID: identity.id, purpose: .password)))
  let host = Host(
    id: profile.id, label: profile.label, hostname: profile.hostname, port: 22, username: "ada",
    profile: profile)
  let coordinator = AuthenticationCoordinator(
    host: host, password: savedPassword, known: KnownHosts(location: path),
    credentials: DeviceCredentialStore(secrets: MemorySecrets()),
    ask: { await person.answer($0, shown: $1) })
  #expect(await coordinator.verify(key))
  return (coordinator, path)
}

@MainActor
@Suite("Handshake questions")
struct HandshakeTests {
  @Test("a saved password answers Password, and the code is asked")
  func passwordThenCode() async {
    let person = Person([["424242"]])
    let (login, path) = await arrhenius(savedPassword: "hunter2", person: person)
    defer { removeDirectory(of: path) }

    #expect(await login.answer(instruction: "", prompts: [password]) == ["hunter2"])
    #expect(await login.answer(instruction: "", prompts: [code]) == ["424242"])
    #expect(person.prompted == ["Verification code: "], "only the code reaches the person")
    #expect(person.notices == [nil])
  }

  /// The failure that hid the verification code: a refused saved password
  /// was sent again, silently, until the server gave up — and nobody was
  /// ever asked anything.
  @Test("a refused saved password is asked for, never sent again")
  func refusedPassword() async {
    let person = Person([["correct"], ["424242"]])
    let (login, path) = await arrhenius(savedPassword: "stale", person: person)
    defer { removeDirectory(of: path) }

    #expect(await login.answer(instruction: "", prompts: [password]) == ["stale"])
    // The server starts over: that is how keyboard-interactive says no.
    #expect(await login.answer(instruction: "", prompts: [password]) == ["correct"])
    #expect(await login.answer(instruction: "", prompts: [code]) == ["424242"])
    #expect(person.prompted == ["Password: ", "Verification code: "])
    #expect(person.notices == ["Password was not accepted.", nil])
  }

  @Test("a refused code is asked again, and the password is not")
  func refusedCode() async {
    let person = Person([["000000"], ["424242"]])
    let (login, path) = await arrhenius(savedPassword: "hunter2", person: person)
    defer { removeDirectory(of: path) }

    #expect(await login.answer(instruction: "", prompts: [password]) == ["hunter2"])
    #expect(await login.answer(instruction: "", prompts: [code]) == ["000000"])
    #expect(await login.answer(instruction: "", prompts: [password]) == ["hunter2"])
    #expect(await login.answer(instruction: "", prompts: [code]) == ["424242"])
    #expect(person.notices == [nil, "Verification code was not accepted."])
  }

  /// A server whose password step is required rather than requisite asks
  /// for the code even when the password was wrong, so the code is blamed
  /// first. Refused again, the saved password is no longer trusted.
  @Test("a saved password refused behind a code is asked for by the second refusal")
  func refusedBehindCode() async {
    let person = Person([["000000"], ["111111"], ["correct"], ["424242"]])
    let (login, path) = await arrhenius(savedPassword: "stale", person: person)
    defer { removeDirectory(of: path) }

    #expect(await login.answer(instruction: "", prompts: [password]) == ["stale"])
    #expect(await login.answer(instruction: "", prompts: [code]) == ["000000"])
    #expect(await login.answer(instruction: "", prompts: [password]) == ["stale"])
    #expect(await login.answer(instruction: "", prompts: [code]) == ["111111"])
    #expect(await login.answer(instruction: "", prompts: [password]) == ["correct"])
    #expect(await login.answer(instruction: "", prompts: [code]) == ["424242"])
    #expect(person.prompted == ["Verification code: ", "Verification code: ", "Password: ", "Verification code: "])
    #expect(person.notices == [nil, "Verification code was not accepted.", "Not accepted.", nil])
  }

  @Test("declining is a decline, not an empty answer")
  func declined() async {
    let person = Person([nil])
    let (login, path) = await arrhenius(savedPassword: "hunter2", person: person)
    defer { removeDirectory(of: path) }

    _ = await login.answer(instruction: "", prompts: [password])
    #expect(await login.answer(instruction: "", prompts: [code]).isEmpty)
  }

  /// A tab closed with a question on screen: the question goes, and the
  /// handshake parked behind it is told no rather than left suspended.
  @Test("cancelling withdraws the question on screen")
  func cancelWithdraws() async {
    let path = temporaryFile("known")
    defer { removeDirectory(of: path) }
    var withdrawn = false
    let host = Host(label: "lab", hostname: key.host, port: 22, username: "ada")
    let login = AuthenticationCoordinator(
      host: host, password: "", known: KnownHosts(location: path),
      credentials: DeviceCredentialStore(secrets: MemorySecrets()),
      ask: { question, shown in
        if case .trust = question { return [] }
        shown()
        // Waits for as long as the question is on screen.
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        withdrawn = true
        return nil
      })
    #expect(await login.verify(key))

    let answering = Task { await login.answer(instruction: "", prompts: [code]) }
    try? await Task.sleep(for: .milliseconds(20))
    login.cancel()
    #expect(await answering.value.isEmpty)
    #expect(withdrawn)
  }

  @Test("a question nobody answers is taken away, and the failure says so")
  func unanswered() async {
    let path = temporaryFile("known")
    defer { removeDirectory(of: path) }
    var withdrawn = false
    let login = AuthenticationCoordinator(
      host: Host(label: "lab", hostname: key.host, port: 22, username: "ada"), password: "",
      known: KnownHosts(location: path), credentials: DeviceCredentialStore(secrets: MemorySecrets()),
      answerTimeout: .milliseconds(30),
      ask: { question, shown in
        if case .trust = question { return [] }
        // Queued behind another dialog for longer than the deadline: not
        // yet a question anyone could have answered.
        try? await Task.sleep(for: .milliseconds(60))
        #expect(!Task.isCancelled, "the deadline starts when the question is shown")
        shown()
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        withdrawn = true
        return nil
      })
    #expect(await login.verify(key))
    #expect(await login.answer(instruction: "", prompts: [code]).isEmpty)
    #expect(withdrawn)
    #expect(login.refusal.map(message(for:)) == "No answer in time.")
  }

  @Test("an answer that arrived is never reported as missing")
  func answeredInTime() async {
    let path = temporaryFile("known")
    defer { removeDirectory(of: path) }
    let login = AuthenticationCoordinator(
      host: Host(label: "lab", hostname: key.host, port: 22, username: "ada"), password: "",
      known: KnownHosts(location: path), credentials: DeviceCredentialStore(secrets: MemorySecrets()),
      answerTimeout: .milliseconds(30),
      ask: { question, shown in
        shown()
        return if case .trust = question { [] } else { ["424242"] }
      })
    #expect(await login.verify(key))
    #expect(await login.answer(instruction: "", prompts: [code]) == ["424242"])
    try? await Task.sleep(for: .milliseconds(60))
    #expect(login.refusal == nil, "a later failure is the server's, not a missing answer")
  }

  @Test("declining an approval is not distrusting the key")
  func approvalDeclined() async {
    let path = temporaryFile("known")
    defer { removeDirectory(of: path) }
    let identity = AccountIdentity(name: "Arrhenius")
    let profile = HostProfile(
      id: UUID(), label: "Arrhenius", hostname: key.host, port: 22, username: "ada",
      authentication: AuthenticationProfile(
        identity: identity, primary: CredentialDescriptor(identityID: identity.id, purpose: .password)))
    let known = KnownHosts(location: path)
    known.remember(key)
    let login = AuthenticationCoordinator(
      host: Host(id: profile.id, label: "Arrhenius", hostname: key.host, port: 22, username: "ada", profile: profile),
      password: "", known: known, credentials: DeviceCredentialStore(secrets: MemorySecrets()),
      ask: { _, _ in nil })
    #expect(await !login.verify(key))
    #expect(login.refusal is CancellationError, "a decision, not a failure to report")
  }

  @Test("the password a person typed is the one offered to be kept, and a code never is")
  func typedPassword() async {
    let person = Person([["correct"], ["424242"]])
    let (login, path) = await arrhenius(savedPassword: "stale", person: person)
    defer { removeDirectory(of: path) }

    _ = await login.answer(instruction: "", prompts: [password])
    #expect(login.typedPassword == nil, "the saved one is already kept")
    _ = await login.answer(instruction: "", prompts: [password])
    _ = await login.answer(instruction: "", prompts: [code])
    #expect(login.typedPassword == "correct")
    login.cancel()
    #expect(login.typedPassword == nil, "gone with the attempt")
  }

  @Test("each question reads as a title and a verb")
  func dialogs() {
    let trust = HandshakeQuestion.trust(key).dialog
    #expect(trust.title == "Unrecognised host")
    #expect(trust.message == key.fingerprint)
    #expect(trust.actions.map(\.title) == ["Reject", "Trust"])
    #expect(trust.defaultAction == 1)

    let approve = HandshakeQuestion.confirmation(title: "Authenticate to Arrhenius", detail: "ada@login").dialog
    #expect(approve.actions.map(\.title) == ["Cancel", "Approve"])

    let verification = HandshakeQuestion.prompts([code], instruction: "", notice: nil).dialog
    #expect(verification.title == "Verification code")
    #expect(verification.message == nil)
    #expect(verification.fields == [Dialog.Field("", kind: .code)], "the title already says what to type")

    let again = HandshakeQuestion.prompts(
      [code], instruction: "Enter the code", notice: "Verification code was not accepted.").dialog
    #expect(again.message == "Verification code was not accepted.")

    let institutional = HandshakeQuestion.prompts(
      [password, AuthPrompt(text: "Username: ", echo: true)], instruction: "Cluster login", notice: nil
    ).dialog
    #expect(institutional.message == "Cluster login", "the server's own words are shown, not parsed")
    #expect(institutional.fields.map(\.kind) == [.password, .text])
    #expect(institutional.fields.map(\.placeholder) == ["", "Username"])
  }

  @Test("an answer is what the person confirmed")
  func answers() {
    let question = HandshakeQuestion.prompts([code], instruction: "", notice: nil)
    #expect(question.answers(from: DialogReply(action: 1, role: .confirm, values: ["424242"])) == ["424242"])
    #expect(question.answers(from: DialogReply(action: 0, role: .cancel, values: ["424242"])) == nil)
    #expect(question.answers(from: nil) == nil)
    #expect(HandshakeQuestion.trust(key).answers(from: DialogReply(action: 1, role: .confirm, values: [])) == [])
  }
}

@Suite("Challenge history")
struct ChallengeHistoryTests {
  @Test("a question that comes back names the answer refused")
  func restart() {
    var history = ChallengeHistory()
    history.begin(["Password"])
    history.record(["Password": .saved])
    history.begin(["Verification code"])
    #expect(history.notice(for: ["Verification code"]) == nil)
    history.record(["Verification code": .person])

    history.begin(["Password"])
    #expect(history.maySave("Password"), "the code was refused, not the password")
    #expect(history.notice(for: ["Password"]) == nil)
    history.record(["Password": .saved])
    history.begin(["Verification code"])
    #expect(history.notice(for: ["Verification code"]) == "Verification code was not accepted.")
  }

  @Test("a refused round of several prompts cannot say which")
  func severalPrompts() {
    var history = ChallengeHistory()
    history.begin(["Password", "Verification code"])
    history.record(["Password": .saved, "Verification code": .person])
    history.begin(["Password", "Verification code"])
    #expect(history.notice(for: ["Password", "Verification code"]) == "Not accepted.")
    #expect(!history.maySave("Password"), "it may have been the saved password")
  }
}
