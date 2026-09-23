import Foundation
import Tether
import Testing

@testable import TetherApp

// `Foundation` exports a `Host` of its own, and qualifying by module name does
// not help here — the app's `@main` type is also called `TetherApp`. Importing
// the one type by name settles it.
import struct TetherApp.Host

/// The parts of a session's state that do not need a server.
@MainActor
@Suite("Session model")
struct SessionModelTests {
  /// The handshake parks on a continuation until a question is answered. A
  /// tab closed while one is on screen would otherwise leave that task
  /// suspended for the life of the process, holding its connection open — a
  /// leak with no symptom until there are enough of them.
  @Test("declining a question answers it in the negative")
  func decliningAnswers() async {
    let prompts: [String] = await withCheckedContinuation { continuation in
      let question = Question(
        kind: .prompts(instruction: "Verification code", prompts: []) {
          continuation.resume(returning: $0)
        })
      question.decline()
    }
    #expect(prompts.isEmpty)

    let trusted: Bool = await withCheckedContinuation { continuation in
      let identity = HostIdentity(
        host: "10.0.0.4", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:aaa")
      let question = Question(
        kind: .trust(host: identity, why: .unknown) { continuation.resume(returning: $0) })
      question.decline()
    }
    #expect(trusted == false, "a question nobody answered is not consent")
  }

  /// These sentences are what a person reads when everything has gone wrong.
  /// They are asserted because a message nothing checks drifts back into the
  /// vocabulary of the thing that failed.
  @Test("every failure says something a person can act on")
  func messages() {
    #expect(message(for: TetherError.cancelled) == "Cancelled.")
    #expect(
      message(for: TetherError.hostRejected(endpoint: "10.0.0.4:22"))
        == "The host key was not trusted.")
    #expect(message(for: TetherError.timedOut(millis: 10_000)).contains("10000"))

    #expect(message(for: TetherError.authenticationFailed(remaining: [])) == "Authentication failed.")
    let remaining = message(for: TetherError.authenticationFailed(remaining: ["publickey", "password"]))
    #expect(remaining.contains("publickey, password"), "a person needs to know what is still on offer")

    #expect(
      message(for: TetherError.moreFactorsNeeded(remaining: ["keyboard-interactive"]))
        .contains("keyboard-interactive"))

    #expect(
      message(for: TetherError.protocolFailure(cause: "no server running")) == "no server running",
      "the session tree must show the cause, not an NSError code")
    #expect(
      !message(for: TetherError.unsupported(what: "a local shell"))
        .localizedCaseInsensitiveContains("couldn't be completed"))

    // Anything that is not ours still has to read as a sentence rather than
    // as an empty box.
    let foreign = NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "the disk went away"])
    #expect(!message(for: foreign).isEmpty)
  }

  /// A configured IdentityFile is the credential. Asking for a password as
  /// well is what `ssh` does not do, and what a person who already has a key
  /// in their ssh config should not see.
  @Test("ssh is invoked with the stanza name, not the resolved address")
  func sshTargetIsTheAlias() {
    let host = Host(
      label: "Arrhenius", hostname: "login.example", port: 22, username: "ada",
      keyPath: "~/.ssh/id_arrhenius_mac")
    #expect(host.sshTarget == "Arrhenius")

    var unnamed = host
    unnamed.label = "  "
    #expect(unnamed.sshTarget == "login.example")
  }

  @Test("a configured key is offered and does not need a password")
  func configuredKeyIsTheCredential() {
    var host = Host(
      label: "Arrhenius", hostname: "login.example", port: 22, username: "ada",
      keyPath: "~/.ssh/id_arrhenius_mac")
    #expect(host.offersConfiguredKey)
    #expect(identityFiles(for: host, readable: { _ in true }) == ["~/.ssh/id_arrhenius_mac"])

    host.keyPath = nil
    #expect(!host.offersConfiguredKey)
    #expect(
      identityFiles(for: host, readable: { $0.hasSuffix("id_ed25519") }) == ["~/.ssh/id_ed25519"],
      "without IdentityFile, the defaults that exist are what ssh would try")
    #expect(identityFiles(for: host, readable: { _ in false }).isEmpty)
  }

  @Test("a saved password fills the account prompt, not a verification code")
  func passwordPromptIsNotACode() {
    #expect(isAccountPasswordPrompt(AuthPrompt(text: "Password: ", echo: false)))
    #expect(isAccountPasswordPrompt(AuthPrompt(text: "Password for ada:", echo: false)))
    #expect(isAccountPasswordPrompt(AuthPrompt(text: "Unix password:", echo: false)))
    #expect(!isAccountPasswordPrompt(AuthPrompt(text: "Password: ", echo: true)))
    #expect(!isAccountPasswordPrompt(AuthPrompt(text: "Verification code:", echo: false)))
    #expect(!isAccountPasswordPrompt(AuthPrompt(text: "One-time password:", echo: false)))
    #expect(!isAccountPasswordPrompt(AuthPrompt(text: "One-time code: ", echo: true)))
    #expect(promptDialogTitle(AuthPrompt(text: "Verification code: ", echo: true)) == "Verification code")
    #expect(promptDialogTitle(AuthPrompt(text: "Password: ", echo: false)) == "Password")
  }

  @Test("a tile letter falls back to the address when there is no name")
  func initials() {
    var host = Host(label: "", hostname: "hpc.example.org", port: 22, username: "ada", keyPath: nil)
    #expect(host.initial == "H")
    host.label = "lab"
    #expect(host.initial == "L")
    host.hostname = ""
    host.label = ""
    #expect(host.initial == "?")
  }
}
