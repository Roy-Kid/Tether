import CloudKit
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class ContinuityService {
  static var active: [String: ContinuityService] = [:]
  private weak var store: HostStore?
  private var database: CKDatabase?
  private let credentials: DeviceCredentialStore
  private let scope: String
  private let zone = CKRecordZone.ID(zoneName: "TetherContinuity")
  private(set) var requests: [ApprovalRequest] = []
  private(set) var discovered: [DeviceCard] = []
  private(set) var problem: String?
  private var stopped = false
  private var waiting: Set<UUID> = []
  private var preparing = false
  private var zoneReady = false

  init(store: HostStore, database: CKDatabase?, credentials: DeviceCredentialStore = DeviceCredentialStore()) {
    self.store = store; self.database = database; self.credentials = credentials; scope = store.scope
    Self.active[scope] = self
  }
  func useDatabase(_ database: CKDatabase?) { self.database = database }
  var local: DeviceCard? { store?.snapshot.trust.local }
  var peers: [TrustedPeer] { Array(store?.snapshot.trust.peers.values ?? [:].values).sorted { $0.card.name < $1.card.name } }

  func enable(name: String) {
    do {
      guard let store, store.snapshot.trust.local == nil else { return }
      let signing = Curve25519.Signing.PrivateKey()
      let agreement = Curve25519.KeyAgreement.PrivateKey()
      let material = DeviceKeyMaterial(signing: signing.rawRepresentation, agreement: agreement.rawRepresentation)
      let secretID = UUID()
      let card = DeviceCard(id: UUID(), name: name, signingKey: signing.publicKey.rawRepresentation,
        agreementKey: agreement.publicKey.rawRepresentation)
      try credentials.write(String(decoding: JSONEncoder().encode(material), as: UTF8.self), id: secretID, label: "Device identity")
      try store.update { $0.trust.local = card; $0.trust.secretID = secretID }
    } catch { problem = error.localizedDescription }
  }

  func pair(_ card: DeviceCard) {
    do {
      guard let store, card.id != local?.id, store.scope == scope else { throw IdentityError.untrustedDevice }
      try store.update { state in
        if let old = state.trust.peers[card.id], old.card != card || old.revoked { throw IdentityError.untrustedDevice }
        state.trust.peers[card.id] = TrustedPeer(card: card)
      }
    } catch { problem = error.localizedDescription }
  }

  func revoke(_ id: UUID) {
    do {
      guard let store, let local else { throw IdentityError.untrustedDevice }
      let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: keys().signing)
      var notices: [UUID: SignedDeviceRevocation] = [:]
      for target in peers where !target.revoked {
        let notice = DeviceRevocation(issuer: local.id, recipient: target.id, revokedDevice: id)
        let payload = try JSONEncoder().encode(notice)
        notices[notice.id] = SignedDeviceRevocation(payload: payload, signature: try signing.signature(for: payload))
      }
      try store.update { state in
        state.trust.peers[id]?.revoked = true
        state.trust.revocations.merge(notices) { _, new in new }
      }
      Task { await refresh() }
      requests.removeAll { $0.sender == id }
    } catch { problem = error.localizedDescription }
  }
  func stop() {
    stopped = true; waiting = []; requests = []
    if Self.active[scope] === self { Self.active.removeValue(forKey: scope) }
  }

  private func keys() throws -> DeviceKeyMaterial {
    guard !stopped, let store, store.scope == scope, !store.snapshot.trust.localRevoked, let id = store.snapshot.trust.secretID else { throw IdentityError.untrustedDevice }
    return try JSONDecoder().decode(DeviceKeyMaterial.self, from: Data(credentials.read(id).utf8))
  }
  private func peer(_ id: UUID) throws -> DeviceCard {
    guard !stopped, let peer = store?.snapshot.trust.peers[id], !peer.revoked else { throw IdentityError.untrustedDevice }
    return peer.card
  }
  private func ready() async throws -> CKDatabase {
    guard !stopped, store?.scope == scope, let database else { throw IdentityError.storage("iCloud is required for device approval.") }
    if !zoneReady {
      _ = try await database.save(CKRecordZone(zoneID: zone))
      zoneReady = true
    }
    return database
  }
  private func publish(_ envelope: DeviceEnvelope, name: String) async throws {
    let database = try await ready()
    let record = CKRecord(recordType: "TetherMessage", recordID: CKRecord.ID(recordName: name, zoneID: zone))
    record["recipient"] = envelope.header.recipient.uuidString
    record["expires"] = envelope.header.expires
    record["envelope"] = try JSONEncoder().encode(envelope)
    _ = try await database.save(record)
  }

  func requestOTP(host: Host, fingerprint: String) async throws -> String {
    guard let profile = host.profile, let otp = profile.authentication.otp,
      let recipient = profile.authentication.remoteApprovalDevice, let local else { throw IdentityError.missingCredential }
    let target = try peer(recipient)
    let now = Date()
    let request = ApprovalRequest(sender: local.id, recipient: recipient, hostID: host.id,
      hostname: host.hostname, port: host.port, username: host.username, hostFingerprint: fingerprint,
      profileDigest: profile.securityDigest, credentialID: otp.id, created: now, expires: now.addingTimeInterval(90))
    waiting.insert(request.id)
    defer { waiting.remove(request.id) }
    let header = DeviceEnvelope.Header(id: request.id, sender: local.id, recipient: recipient, expires: request.expires, kind: "otp-request")
    let name = "request-" + request.id.uuidString
    let responseID = CKRecord.ID(recordName: "response-" + request.id.uuidString, zoneID: zone)
    try await publish(DeviceEnvelope.seal(request, header: header, keys: keys(), peer: target), name: name)
    let database = try await ready()
    defer {
      Task { _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: name, zoneID: zone)); _ = try? await database.deleteRecord(withID: responseID) }
    }
    while Date() < request.expires {
      try Task.checkCancellation()
      guard waiting.contains(request.id), !stopped else { throw CancellationError() }
      _ = try peer(recipient)
      do {
        let record = try await database.record(for: responseID)
        guard let data = record["envelope"] as? Data else { throw IdentityError.invalidConfiguration }
        let envelope = try JSONDecoder().decode(DeviceEnvelope.self, from: data)
        guard envelope.header.kind == "otp-response", envelope.header.id == request.id else { throw IdentityError.untrustedDevice }
        let response = try envelope.open(ApprovalResponse.self, local: local, keys: keys(), peer: target)
        guard response.request == request, response.validUntil > Date(),
          response.validUntil <= request.expires else { throw IdentityError.expired }
        try consume(request.id, expires: request.expires)
        guard let code = response.code, [6, 8].contains(code.count), code.allSatisfy(\.isNumber) else { throw CancellationError() }
        return code
      } catch let error as CKError where error.code == .unknownItem { }
      try await Task.sleep(for: .seconds(2))
    }
    throw IdentityError.expired
  }

  /// Called while the device approvals screen is open. No background availability
  /// promise: the user can open the companion app to receive a request.
  func refresh() async {
    guard !preparing, let local else { return }
    preparing = true
    defer { preparing = false }
    do {
      let database = try await ready()
      try await syncDeviceDirectory(database, local: local)
      try await syncRevocations(database, local: local)
      guard store?.snapshot.trust.localRevoked == false else { throw IdentityError.untrustedDevice }
      let query = CKQuery(recordType: "TetherMessage", predicate: NSPredicate(format: "recipient == %@", local.id.uuidString))
      let (records, _) = try await database.records(matching: query, inZoneWith: zone, resultsLimit: 100)
      var pending: [ApprovalRequest] = []
      for (id, result) in records {
        guard let record = try? result.get(), let data = record["envelope"] as? Data,
          let envelope = try? JSONDecoder().decode(DeviceEnvelope.self, from: data) else { continue }
        if envelope.header.expires <= Date() { _ = try? await database.deleteRecord(withID: id); continue }
        guard envelope.header.kind == "otp-request", let sender = try? peer(envelope.header.sender),
          let request = try? envelope.open(ApprovalRequest.self, local: local, keys: keys(), peer: sender),
          request.id == envelope.header.id, request.sender == sender.id, request.recipient == local.id,
          request.expires == envelope.header.expires, request.created <= Date().addingTimeInterval(5),
          request.expires.timeIntervalSince(request.created) <= 90,
          store?.snapshot.trust.consumed[request.id] == nil else { continue }
        pending.append(request)
      }
      requests = pending.sorted { $0.created < $1.created }
      problem = nil
    } catch { problem = error.localizedDescription }
  }

  func respond(_ request: ApprovalRequest, approve: Bool, known: KnownHosts) async {
    do {
      guard requests.contains(request), request.expires > Date(), let local, let store,
        let record = store.snapshot.records[request.hostID], !record.deleted, record.conflicts.isEmpty,
        store.snapshot.approvals[request.hostID] == request.profileDigest,
        record.profile.securityDigest == request.profileDigest,
        record.profile.hostname == request.hostname, record.profile.port == request.port,
        record.profile.username == request.username,
        record.profile.authentication.otp?.id == request.credentialID,
        known.entries.contains(where: { $0.endpoint == "\(request.hostname):\(request.port)" && $0.fingerprint == request.hostFingerprint })
      else { throw IdentityError.needsReview }
      let target = try peer(request.sender)
      var code: String?
      var validUntil = request.expires
      if approve {
        guard let secretID = store.snapshot.bindings[request.credentialID]?.secretID else { throw IdentityError.missingCredential }
        let otp = try JSONDecoder().decode(TOTP.self, from: Data(credentials.read(secretID).utf8))
        code = try otp.code()
        let boundary = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / Double(otp.period)) + 1) * Double(otp.period))
        validUntil = min(request.expires, boundary)
      }
      // Commit consumption before sending: a transport failure cannot issue the
      // same approval twice. The requesting device can start a new attempt.
      try consume(request.id, expires: request.expires)
      requests.removeAll { $0.id == request.id }
      let response = ApprovalResponse(request: request, code: code, validUntil: validUntil)
      let header = DeviceEnvelope.Header(id: request.id, sender: local.id, recipient: request.sender, expires: request.expires, kind: "otp-response")
      try await publish(DeviceEnvelope.seal(response, header: header, keys: keys(), peer: target), name: "response-" + request.id.uuidString)
    } catch { problem = error.localizedDescription }
  }

  private func syncDeviceDirectory(_ database: CKDatabase, local: DeviceCard) async throws {
    let id = CKRecord.ID(recordName: local.id.uuidString, zoneID: zone)
    // Keep the directory public-material-only and explicitly untrusted.
    let record: CKRecord
    do { record = try await database.record(for: id) }
    catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "TetherDevice", recordID: id) }
    let data = try JSONEncoder().encode(local)
    if record["card"] as? Data != data { record["card"] = data; _ = try await database.save(record) }
    let (records, _) = try await database.records(matching: CKQuery(recordType: "TetherDevice", predicate: NSPredicate(value: true)), inZoneWith: zone, resultsLimit: 100)
    discovered = records.compactMap { _, result in
      guard let record = try? result.get(), let data = record["card"] as? Data,
        let card = try? JSONDecoder().decode(DeviceCard.self, from: data), card.id != local.id else { return nil }
      return card
    }
  }

  private func syncRevocations(_ database: CKDatabase, local: DeviceCard) async throws {
    guard let store else { return }
    for (id, signed) in store.snapshot.trust.revocations {
      let notice = try JSONDecoder().decode(DeviceRevocation.self, from: signed.payload)
      let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zone)
      let record: CKRecord
      do { record = try await database.record(for: recordID) }
      catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "TetherRevocation", recordID: recordID) }
      record["recipient"] = notice.recipient.uuidString
      record["issuer"] = notice.issuer.uuidString
      record["notice"] = try JSONEncoder().encode(signed)
      _ = try await database.save(record)
    }
    let query = CKQuery(recordType: "TetherRevocation", predicate: NSPredicate(format: "recipient == %@", local.id.uuidString))
    let (records, _) = try await database.records(matching: query, inZoneWith: zone, resultsLimit: 100)
    for (_, result) in records {
      guard let record = try? result.get(), let sender = record["issuer"] as? String,
        let senderID = UUID(uuidString: sender), let peer = try? peer(senderID),
        let data = record["notice"] as? Data,
        let signed = try? JSONDecoder().decode(SignedDeviceRevocation.self, from: data),
        let notice = try? signed.verify(using: peer), notice.recipient == local.id else { continue }
      try store.update { state in
        if notice.revokedDevice == local.id { state.trust.localRevoked = true }
        state.trust.peers[notice.revokedDevice]?.revoked = true
      }
      requests.removeAll { $0.sender == notice.revokedDevice }
      if notice.revokedDevice == local.id { waiting = []; requests = [] }
    }
  }

  private func consume(_ id: UUID, expires: Date) throws {
    guard let store else { throw IdentityError.untrustedDevice }
    try store.update { state in
      state.trust.consumed = state.trust.consumed.filter { $0.value > Date() }
      guard state.trust.consumed[id] == nil else { throw IdentityError.expired }
      state.trust.consumed[id] = expires
    }
  }
}
