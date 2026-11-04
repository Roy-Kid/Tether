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

}
