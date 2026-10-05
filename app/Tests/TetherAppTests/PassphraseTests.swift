import Foundation
import Tether
import TetherUI
import Testing

@testable import TetherApp

import struct TetherApp.Host

/// A private key's passphrase is asked like every other question a login
/// asks: through the one dialog path, only once the host is trusted and the
/// login approved, and a person's no ends it as a no.
@MainActor
@Suite("Key passphrases")
struct PassphraseTests {
  private let identity = HostIdentity(
    host: "login.example.org", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:fixture")
  private let locked = LockedKey(fingerprint: "SHA256:key", comment: "")

  private func coordinator(
    _ answer: @escaping @MainActor (HandshakeQuestion) -> [String]?
  ) -> (AuthenticationCoordinator, URL) {
    let path = temporaryFile("known")
    let host = Host(label: "Arrhenius", hostname: identity.host, port: 22, username: "ada", keyPath: nil)
    let login = AuthenticationCoordinator(
      host: host, password: "", known: KnownHosts(location: path),
      credentials: DeviceCredentialStore(secrets: MemorySecrets()),
      ask: { question, shown in
        shown()
        return answer(question)
      })
    return (login, path)
  }

  @Test("the dialog is a title and a verb, and says which key")
  func dialog() {
    let first = HandshakeQuestion.passphrase(key: "id_ed25519", fingerprint: "SHA256:key", notice: nil).dialog
    #expect(first.title == "Unlock id_ed25519")
    #expect(first.message == "SHA256:key")
    #expect(first.fields == [Dialog.Field("Passphrase", kind: .password)])
    #expect(first.actions.map(\.title) == ["Cancel", "Unlock"])

    let again = HandshakeQuestion.passphrase(
      key: "id_ed25519", fingerprint: "SHA256:key", notice: "The passphrase was not accepted."
    ).dialog
    #expect(again.message == "The passphrase was not accepted.")
  }

  @Test("nothing is asked before the host is trusted")
  func notBeforeTrust() async {
    var asked = 0
    let (login, path) = coordinator { _ in asked += 1; return ["open sesame"] }
    defer { removeDirectory(of: path) }

    #expect(await login.passphrase(forKey: "id_ed25519", locked, attempt: 1) == nil)
    #expect(asked == 0)
  }

  @Test("the passphrase typed is the one handed over, and a retry says why")
  func asked() async {
    var questions: [HandshakeQuestion] = []
    let (login, path) = coordinator { question in
      questions.append(question)
      if case .trust = question { return [] }
      return ["open sesame"]
    }
    defer { removeDirectory(of: path) }
    #expect(await login.verify(identity))

    #expect(await login.passphrase(forKey: "id_ed25519", locked, attempt: 1) == "open sesame")
    #expect(await login.passphrase(forKey: "id_ed25519", locked, attempt: 2) == "open sesame")
    let notices = questions.compactMap { question -> String?? in
      if case .passphrase(_, _, let notice) = question { notice } else { nil }
    }
    #expect(notices == [nil, "The passphrase was not accepted."])
  }

  @Test("closing the dialog is the person's no")
  func declined() async {
    let (login, path) = coordinator { question in
      if case .trust = question { return [] }
      return nil
    }
    defer { removeDirectory(of: path) }
    #expect(await login.verify(identity))

    #expect(await login.passphrase(forKey: "id_ed25519", locked, attempt: 1) == nil)
    #expect(login.refusal is CancellationError, "a no ends the login quietly")
  }

  @Test("a key left out is named by its file, and other failures pass through")
  func skippedKeysAreNamed() {
    let skipped = SkippedKey(position: 1, fingerprint: "SHA256:key", problem: .wrongPassphrase)
    let named = namingSkippedKeys(
      TetherError.authenticationFailed(remaining: ["publickey"], skipped: [skipped]),
      [0: "id_rsa", 1: "id_ed25519"])
    #expect(
      named as? TetherError
        == .authenticationFailed(
          remaining: ["publickey"],
          skipped: [SkippedKey(position: 1, fingerprint: "SHA256:key", problem: .wrongPassphrase, name: "id_ed25519")]))
    #expect(
      named.localizedDescription
        == "Authentication failed. The server accepts: publickey. id_ed25519 was not used: the passphrase was not accepted.")

    #expect(namingSkippedKeys(TetherError.cancelled, [0: "id_rsa"]) as? TetherError == .cancelled)
    #expect(keyName("~/.ssh/id_ed25519") == "id_ed25519")
  }
}
