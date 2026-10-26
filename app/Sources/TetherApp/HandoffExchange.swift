import CryptoKit
import Foundation

/// This device, as the handshake knows it: the card, the signing key, and
/// the peers it will talk to. A revoked peer is present so it can be refused.
struct HandoffPrincipal {
  var card: DeviceCard
  var keys: DeviceKeyMaterial
  var peers: [UUID: TrustedPeer]
}

/// One length-prefixed message. A struct, so the coding is the fields and
/// nothing else decides what a stranger can send.
struct HandoffWire: Codable, Equatable {
  var kind: String
  var id: UUID?
  var nonce: Data?
  var payload: Data?
}

enum HandoffPhase: Equatable {
  case fresh
  case announced
  case open
  case refused
}

enum HandoffEvent: Equatable {
  case reply(HandoffWire)
  case snapshot(HandoffSnapshot)
  case idle
}

/// Pairing proof, then the snapshot.
///
/// Both sides announce themselves first. A proof signs the peer's nonce, so
/// a copied hello is not a proof. The snapshot is sealed with a key both
/// sides derive only after that proof, and nothing is sealed before it.
@MainActor
final class HandoffExchange {
  let principal: HandoffPrincipal
  private(set) var phase: HandoffPhase = .fresh
  private var localNonce = Data()
  private var peer: TrustedPeer?
  /// Set once a trusted hello has been accepted. The service routes on it.
  private(set) var acceptedID: UUID?
  private var peerNonce: Data?
  private var snapshotKey: SymmetricKey?

  init(principal: HandoffPrincipal) {
    self.principal = principal
  }

  func start() -> HandoffWire {
    guard phase != .refused else { return HandoffWire(kind: "refuse") }
    if phase == .fresh {
      localNonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
      phase = .announced
    }
    return HandoffWire(kind: "hello", id: principal.card.id, nonce: localNonce)
  }

  func receive(_ wire: HandoffWire) -> HandoffEvent {
    if phase == .refused { return .reply(HandoffWire(kind: "refuse")) }
    switch wire.kind {
    case "hello": return receiveHello(wire)
    case "proof": return receiveProof(wire)
    case "snapshot":
      if let snapshot = open(wire) { return .snapshot(snapshot) }
      return .idle
    case "refuse":
      phase = .refused
      snapshotKey = nil
      return .idle
    default:
      return refuse()
    }
  }

  /// Nil until the peer's proof has been checked.
  func seal(_ snapshot: HandoffSnapshot) -> HandoffWire? {
    guard phase == .open, let snapshotKey,
      let clear = try? JSONEncoder().encode(snapshot),
      let combined = try? AES.GCM.seal(clear, using: snapshotKey).combined else { return nil }
    return HandoffWire(kind: "snapshot", payload: combined)
  }

  func open(_ wire: HandoffWire) -> HandoffSnapshot? {
    guard phase == .open, wire.kind == "snapshot", let payload = wire.payload, let snapshotKey,
      let box = try? AES.GCM.SealedBox(combined: payload),
      let clear = try? AES.GCM.open(box, using: snapshotKey) else { return nil }
    return try? JSONDecoder().decode(HandoffSnapshot.self, from: clear)
  }

  /// The TLS pre-shared key for one peer. It does not use the nonces: TLS
  /// starts before either side has seen the other's hello. The snapshot key
  /// is a different derivation.
  static func transportKey(local: DeviceKeyMaterial, peer: DeviceCard) -> SymmetricKey? {
    shared(local: local, peer: peer)?.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: Data("tether-handoff-tls-v1".utf8), sharedInfo: Data(), outputByteCount: 32)
  }

  private func receiveHello(_ wire: HandoffWire) -> HandoffEvent {
    guard phase == .announced || phase == .open else { return refuse() }
    guard let id = wire.id, let nonce = wire.nonce, nonce.count == 32 else { return refuse() }
    if peer?.id == id { return peerNonce == nonce ? .idle : refuse() }
    guard id != principal.card.id, let found = principal.peers[id], !found.revoked else { return refuse() }
    guard peer == nil else { return refuse() }
    peer = found
    acceptedID = id
    peerNonce = nonce
    guard let signature = try? Curve25519.Signing.PrivateKey(rawRepresentation: principal.keys.signing)
      .signature(for: transcript(signer: principal.card.id, other: id, nonce: nonce)) else { return refuse() }
    return .reply(HandoffWire(kind: "proof", payload: signature))
  }

  private func receiveProof(_ wire: HandoffWire) -> HandoffEvent {
    guard phase == .announced, let peer, let payload = wire.payload, payload.count == 64,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: peer.card.signingKey),
      publicKey.isValidSignature(payload, for: transcript(signer: peer.card.id, other: principal.card.id, nonce: localNonce)),
      let key = derive() else { return refuse() }
    snapshotKey = key
    phase = .open
    return .idle
  }

  private func refuse() -> HandoffEvent {
    phase = .refused
    snapshotKey = nil
    return .reply(HandoffWire(kind: "refuse"))
  }

  private func transcript(signer: UUID, other: UUID, nonce: Data) -> Data {
    var data = Data("tether-handoff-v1".utf8)
    data.append(contentsOf: signer.uuidString.utf8)
    data.append(contentsOf: other.uuidString.utf8)
    data.append(nonce)
    return data
  }

  private func derive() -> SymmetricKey? {
    guard let peer, let peerNonce else { return nil }
    guard let secret = Self.shared(local: principal.keys, peer: peer.card) else { return nil }
    let salt = [localNonce, peerNonce].sorted { $0.lexicographicallyPrecedes($1) }.reduce(into: Data()) { $0.append($1) }
    return secret.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: salt, sharedInfo: Data("tether-handoff-snapshot-v1".utf8), outputByteCount: 32)
  }

  private static func shared(local: DeviceKeyMaterial, peer: DeviceCard) -> SharedSecret? {
    guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: local.agreement),
      let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.agreementKey) else { return nil }
    return try? privateKey.sharedSecretFromKeyAgreement(with: publicKey)
  }
}

/// Length-prefixed JSON. A split chunk waits; a length past the cap fails
/// the stream instead of buffering it.
struct HandoffFramer {
  static let maximum = 1_048_576
  private var buffer = Data()
  private(set) var failed = false

  mutating func append(_ data: Data) -> [HandoffWire] {
    guard !failed else { return [] }
    buffer.append(data)
    var wires: [HandoffWire] = []
    while buffer.count >= 4 {
      let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
      guard length > 0, length <= Self.maximum else {
        failed = true
        buffer.removeAll()
        return wires
      }
      guard buffer.count >= 4 + length else { break }
      let body = buffer.subdata(in: 4..<(4 + length))
      buffer.removeSubrange(0..<(4 + length))
      guard let wire = try? JSONDecoder().decode(HandoffWire.self, from: body) else {
        failed = true
        buffer.removeAll()
        return wires
      }
      wires.append(wire)
    }
    return wires
  }

  static func frame(_ wire: HandoffWire) -> Data? {
    guard let body = try? JSONEncoder().encode(wire), body.count <= maximum else { return nil }
    var framed = Data()
    let length = UInt32(body.count)
    framed.append(UInt8(length >> 24))
    framed.append(UInt8((length >> 16) & 0xff))
    framed.append(UInt8((length >> 8) & 0xff))
    framed.append(UInt8(length & 0xff))
    framed.append(body)
    return framed
  }
}
