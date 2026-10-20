import Foundation
import Testing
import Tether
@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Authentication policy enforcement")
struct AuthenticationPolicyTests {
  @Test("a saved code automatically answers after reopening the library without a device approval identity")
  func savedCodeAfterReopening() async throws {
    let location = temporaryFile("config")
    defer { removeDirectory(of: location) }
    let credentials = DeviceCredentialStore(secrets: MemorySecrets())
    let secrets = MemorySecrets()
    let store = HostStore(location: location, secrets: secrets, credentials: credentials)
    #expect(store.save(HostStoreTests.host()))
    let seed = try TOTP(importing: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    try store.setOTP(seed, for: #require(store.hosts.first))

    let reopened = HostStore(location: location, secrets: secrets, credentials: credentials)
    let host = try #require(reopened.hosts.first)
    #expect(reopened.snapshot.trust.secretID == nil)
    #expect(host.profile?.authentication.remoteApprovalDevice == nil)
    let known = KnownHosts(location: location.appendingPathExtension("known"))
    let key = HostIdentity(host: host.hostname, port: host.port, algorithm: "ssh-ed25519", fingerprint: "SHA256:fixture")
    known.remember(key)
    let coordinator = AuthenticationCoordinator(host: host, password: "", known: known, credentials: credentials,
      ask: { _, _ in Issue.record("A saved code must answer without a manual prompt or device setup"); return nil })
    #expect(await coordinator.verify(key))
    let before = try seed.code()
    let answer = await coordinator.answer(instruction: "", prompts: [AuthPrompt(text: "Verification code:", echo: false)])
    let after = try seed.code()
    #expect(answer == [before] || answer == [after])
    coordinator.cancel()
  }

  @Test func otpNeverReleasedBeforeHostVerificationOrForAnotherPrompt() async throws {
    let path = temporaryFile("known")
    defer { removeDirectory(of: path) }
    let known = KnownHosts(location: path)
    let identity = AccountIdentity(name: "KTH")
    let otp = CredentialDescriptor(identityID: identity.id, purpose: .totp)
    let profile = HostProfile(id: UUID(), label: "lab", hostname: "login.example.org", port: 22, username: "ada",
      authentication: AuthenticationProfile(identity: identity,
        primary: CredentialDescriptor(identityID: identity.id, purpose: .ssh), otp: otp))
    let secretID = UUID()
    let memory = MemorySecrets()
    let credentials = DeviceCredentialStore(secrets: memory)
    let seed = try TOTP(importing: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    try credentials.write(String(decoding: JSONEncoder().encode(seed), as: UTF8.self), id: secretID, label: "Test")
    let host = Host(id: profile.id, label: profile.label, hostname: profile.hostname, port: profile.port,
      username: profile.username, profile: profile, otpSecretID: secretID)
    var asked: [String] = []
    let coordinator = AuthenticationCoordinator(host: host, password: "", known: known, credentials: credentials,
      ask: { question, _ in
        switch question {
        case .trust: asked.append("trust"); return []
        case .confirmation: asked.append("confirm"); return []
        case .prompts: asked.append("manual"); return nil
        case .passphrase: asked.append("passphrase"); return nil
        }
      })
    let prompt = AuthPrompt(text: "Verification code:", echo: false)
    #expect(await coordinator.answer(instruction: "", prompts: [prompt]).isEmpty)
    #expect(asked.isEmpty)
    let key = HostIdentity(host: profile.hostname, port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:fixture")
    #expect(await coordinator.verify(key))
    #expect(asked == ["trust", "confirm"])
    #expect(await coordinator.answer(instruction: "", prompts: [AuthPrompt(text: "Enter token", echo: false)]).isEmpty)
    #expect(asked.last == "manual")
    let code = await coordinator.answer(instruction: "", prompts: [prompt])
    #expect(code.count == 1)
    #expect(code.first?.count == 6)
    // Asked again, the stored code was refused: it is not released twice,
    // and the person is asked instead.
    #expect(await coordinator.answer(instruction: "", prompts: [prompt]).isEmpty)
    #expect(asked.last == "manual")
    coordinator.cancel()
    #expect(await coordinator.answer(instruction: "", prompts: [prompt]).isEmpty)
  }

  @Test func changedHostKeyFailsWithoutOverwritingPin() async {
    let path = temporaryFile("known")
    defer { removeDirectory(of: path) }
    let known = KnownHosts(location: path)
    known.remember(HostIdentity(host: "example.org", port: 22, algorithm: "ssh-ed25519", fingerprint: "original"))
    let coordinator = AuthenticationCoordinator(host: Host(label: "lab", hostname: "example.org", port: 22, username: "ada"),
      password: "", known: known, credentials: DeviceCredentialStore(secrets: MemorySecrets()),
      ask: { _, _ in Issue.record("Changed pins must not offer a trust override during authentication"); return nil })
    #expect(await !coordinator.verify(HostIdentity(host: "example.org", port: 22, algorithm: "ssh-ed25519", fingerprint: "changed")))
    #expect(known.entries.first?.fingerprint == "original")
  }
}
