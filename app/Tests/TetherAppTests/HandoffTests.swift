import CryptoKit
import Foundation
import Testing

@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Handoff")
struct HandoffTests {
  private struct FixtureSession: Codable, Equatable {
    var sessionID: String
    var sessionName: String
  }

  private func device(_ name: String) -> (DeviceCard, DeviceKeyMaterial) {
    IdentityTests().device(name)
  }

  private func principal(_ name: String, peers: [TrustedPeer] = []) -> HandoffPrincipal {
    let (card, keys) = device(name)
    return HandoffPrincipal(card: card, keys: keys, peers: Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0) }))
  }

  private func snapshot() -> HandoffSnapshot {
    let host = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: nil)
    let tabs = TabSet()
    tabs.adopt(SessionTab(preview: host, known: KnownHosts(), name: "shell", live: false))
    return tabs.captureHandoff()!
  }

  private func open(_ left: HandoffExchange, _ right: HandoffExchange) {
    let helloLeft = left.start()
    let helloRight = right.start()
    guard case .reply(let proofLeft) = left.receive(helloRight),
      case .reply(let proofRight) = right.receive(helloLeft) else {
      Issue.record("a trusted hello did not produce a proof")
      return
    }
    _ = left.receive(proofRight)
    _ = right.receive(proofLeft)
  }

  @Test("a restored workspace keeps the host, the focus and the session, and drops secrets and localhost")
  func restoresWorkspace() throws {
    let password = UUID()
    let credential = UUID()
    let otp = UUID()
    let keyPath = "/no/such/handoff-key"
    let remote = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: keyPath,
      credentialSecretID: credential, otpSecretID: otp, passwordSecretID: password)
    let gone = Host(label: "gone", hostname: "gone.example", port: 22, username: "ada", keyPath: nil)
    let session = FixtureSession(sessionID: "%7", sessionName: "work")
    let state = try JSONEncoder().encode(session)

    let sender = TabSet()
    sender.adopt(SessionTab(preview: .local, known: sender.known, name: "Local", live: true))
    let shell = SessionTab(preview: remote, known: sender.known, name: "shell", live: true, directory: "/srv/work")
    let editor = SessionTab(preview: remote, known: sender.known, name: "editor", live: true)
    editor.pinnedName = "Notes"
    let attachment = StubAttachment()
    attachment.restorationState = state
    editor.attach(attachment, for: "fixture.session")
    sender.adopt(shell)
    sender.adopt(editor, in: sender.currentWorkspace?.id)
    if let index = sender.workspaces.firstIndex(where: { $0.host.id == remote.id }) {
      sender.workspaces[index].name = "Build"
    }
    sender.adopt(SessionTab(preview: gone, known: sender.known, name: "elsewhere", live: true))
    sender.select(editor.id)

    let captured = try #require(sender.captureHandoff())
    let encoded = String(decoding: try JSONEncoder().encode(captured), as: UTF8.self)
    for secret in [keyPath, password.uuidString, password.uuidString.lowercased(), credential.uuidString, otp.uuidString] {
      #expect(!encoded.contains(secret))
    }
    let remotePage = try #require(captured.pages.first { $0.hostID == remote.id })
    #expect(remotePage.terminals.contains { $0.directory == "/srv/work" })
    #expect(captured.pages[captured.selected].hostID == remote.id)

    var library = remote
    library.keyPath = nil
    library.credentialSecretID = nil
    library.otpSecretID = nil
    library.passwordSecretID = nil
    let receiver = TabSet()
    #expect(receiver.acceptHandoff(captured, hosts: [library, .local], allowLocal: false))
    #expect(receiver.tabs.allSatisfy { !$0.host.isLocal && $0.host.id == remote.id })
    #expect(receiver.currentHost?.keyPath == nil)
    #expect(receiver.currentHost?.passwordSecretID == nil)
    #expect(receiver.current?.name == "editor")
    #expect(receiver.current?.pinnedName == "Notes")
    #expect(receiver.currentWorkspace?.name == "Build")
    #expect(receiver.tabs.allSatisfy { $0.handoff })
    let restored = try #require(receiver.handoffRestores.first { $0.pluginID == "fixture.session" })
    #expect(try JSONDecoder().decode(FixtureSession.self, from: restored.state) == session)
    #expect(!receiver.tabs.contains { $0.name == "elsewhere" || $0.name == "Local" })
  }

  @Test("take over stays disabled until a paired device is nearby and a remote workspace is open")
  func takeOverGate() {
    let tabs = TabSet()
    let remote = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: nil)
    tabs.adopt(SessionTab(preview: .local, known: tabs.known, name: "Local", live: true))
    tabs.takeOverReady = true
    #expect(!tabs.canPerform(.takeOver))
    tabs.adopt(SessionTab(preview: remote, known: tabs.known, name: "shell", live: true))
    #expect(tabs.canPerform(.takeOver))
    tabs.perform(.takeOver)
    #expect(tabs.intent == .takeOver)
    tabs.takeOverReady = false
    #expect(!tabs.canPerform(.takeOver))
  }

  @Test("a snapshot is sealed only after both proofs, and a stranger or a revoked peer gets nothing")
  func provesThenSeals() throws {
    let (macCard, macKeys) = device("Mac")
    let (phoneCard, phoneKeys) = device("Phone")
    let (strangerCard, strangerKeys) = device("Stranger")
    let mac = HandoffExchange(principal: HandoffPrincipal(card: macCard, keys: macKeys, peers: [
      phoneCard.id: TrustedPeer(card: phoneCard),
    ]))
    let phone = HandoffExchange(principal: HandoffPrincipal(card: phoneCard, keys: phoneKeys, peers: [
      macCard.id: TrustedPeer(card: macCard),
    ]))
    let sample = snapshot()
    #expect(mac.seal(sample) == nil)
    _ = mac.start()
    #expect(mac.seal(sample) == nil)
    open(mac, phone)
    #expect(mac.phase == .open)
    #expect(phone.phase == .open)
    let sealed = try #require(mac.seal(sample))
    #expect(phone.open(sealed) == sample)
    var tampered = sealed
    tampered.payload?[0] ^= 0xff
    #expect(phone.open(tampered) == nil)

    let stranger = HandoffExchange(principal: HandoffPrincipal(card: strangerCard, keys: strangerKeys, peers: [:]))
    let strangerHello = stranger.start()
    let refused = mac.receive(strangerHello)
    guard case .reply(let refusal) = refused else {
      Issue.record("a stranger was not refused")
      return
    }
    #expect(refusal.kind == "refuse")
    #expect(mac.phase == .refused)
    #expect(mac.seal(sample) == nil)
    if case .reply(let again) = mac.receive(strangerHello) {
      #expect(again.kind == "refuse")
    } else {
      Issue.record("a repeated hello left the refusal")
    }
    #expect(mac.phase == .refused)

    var revoked = TrustedPeer(card: phoneCard)
    revoked.revoked = true
    let wary = HandoffExchange(principal: HandoffPrincipal(card: macCard, keys: macKeys, peers: [phoneCard.id: revoked]))
    _ = wary.start()
    guard case .reply(let revokedReply) = wary.receive(phone.start()) else {
      Issue.record("a revoked peer was not refused")
      return
    }
    #expect(revokedReply.kind == "refuse")
    #expect(wary.seal(sample) == nil)

    let early = HandoffExchange(principal: HandoffPrincipal(card: macCard, keys: macKeys, peers: [
      phoneCard.id: TrustedPeer(card: phoneCard),
    ]))
    _ = early.start()
    guard case .reply(let earlyReply) = early.receive(HandoffWire(kind: "proof", payload: Data(repeating: 1, count: 64))) else {
      Issue.record("a proof before the hello was accepted")
      return
    }
    #expect(earlyReply.kind == "refuse")
    #expect(early.phase == .refused)
    #expect(early.seal(sample) == nil)
  }

  @Test("a split frame waits, and a length past the cap fails the stream")
  func frames() throws {
    let wire = HandoffWire(kind: "hello", id: UUID(), nonce: Data(repeating: 3, count: 32))
    let framed = try #require(HandoffFramer.frame(wire))
    var framer = HandoffFramer()
    #expect(framer.append(framed.prefix(3)).isEmpty)
    #expect(!framer.failed)
    #expect(framer.append(framed.dropFirst(3)) == [wire])

    var oversize = HandoffFramer()
    _ = oversize.append(Data([0x01, 0x00, 0x00, 0x01]))
    #expect(oversize.failed)
    #expect(oversize.append(framed).isEmpty)
  }

  @Test("the saved snapshot is readable once and then gone")
  func archives() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "tether-handoff-\(UUID().uuidString)")
    let file = root.appending(path: "handoff.json")
    let archive = HandoffArchive(file: file)
    let sample = snapshot()
    archive.save(sample)
    #expect(archive.load() == sample)
    let mode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
    #expect(mode & 0o777 == 0o600)
    #expect(archive.consume() == sample)
    #expect(archive.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try? FileManager.default.removeItem(at: root)
  }
}
