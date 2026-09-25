import CloudKit
import Foundation
import Security

/// CloudKit transports configuration only. Keychain identifiers, approvals and
/// local bindings are excluded by construction from the record payload.
@MainActor
final class HostCloudSync: CKSyncEngineDelegate {
  private weak var store: HostStore?
  private var engine: CKSyncEngine?
  private var container: CKContainer?
  private var starting = false
  private let zone = CKRecordZone.ID(zoneName: "TetherHosts")
  private var account: String?
  var continuityDatabase: CKDatabase? { engine == nil ? nil : container?.privateCloudDatabase }

  init(store: HostStore) { self.store = store }

  func start() async {
    guard !starting else { return }
    if engine != nil { return }
    starting = true
    defer { starting = false }
    // Calling CloudKit from an ad-hoc signed binary can raise an Objective-C
    // exception. Inspect the entitlement before creating a container.
    let identifier: String
    #if os(macOS)
    guard let task = SecTaskCreateFromSelf(nil),
      let identifiers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
      let configured = identifiers.first
    else { store?.setSyncStatus("iCloud unavailable in this build"); return }
    identifier = configured
    #else
    // iOS has no public SecTask entitlement API. A provisioned app build opts in
    // through its Info.plist; simulator/ad-hoc bundles omit this key.
    guard let configured = Bundle.main.object(forInfoDictionaryKey: "TetherCloudContainer") as? String,
      configured.hasPrefix("iCloud.") else { store?.setSyncStatus("iCloud unavailable in this build"); return }
    identifier = configured
    #endif
    let container = CKContainer(identifier: identifier)
    self.container = container
    do {
      let status = try await container.accountStatus()
      if status == .noAccount {
        try store?.switchAccount("local")
        store?.setSyncStatus("Sign in to iCloud to sync")
        return
      }
      guard status == .available else {
        store?.setSyncStatus("iCloud temporarily unavailable; using the offline library")
        return
      }
      let user = try await container.userRecordID()
      try activate(user.recordName, container: container)
      await synchronize()
    } catch { store?.setSyncStatus("Sync failed: \(error.localizedDescription)") }
  }

  private func activate(_ user: String, container: CKContainer) throws {
    guard let store else { return }
    let scope = "icloud:" + user
    try store.switchAccount(scope)
    account = scope
    let state = try store.snapshot.syncState.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
      stateSerialization: state, delegate: self)
    // Foreground sync is explicit; automatic sync also runs when the system permits.
    configuration.automaticallySync = true
    engine = CKSyncEngine(configuration)
    if state == nil { engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))]) }
    enqueue()
  }

  func enqueue() {
    guard let store, let engine, account == store.scope else { return }
    let pending = store.snapshot.records.values.filter { $0.dirty && $0.conflicts.isEmpty }.map {
      CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0.profile.id.uuidString, zoneID: zone))
    }
    engine.state.add(pendingRecordZoneChanges: pending)
    store.setSyncStatus(pending.isEmpty ? "Synced" : "Changes waiting to sync")
  }

  func synchronize() async {
    guard let engine else { await start(); return }
    do {
      store?.setSyncStatus("Syncing")
      try await engine.fetchChanges()
      enqueue()
      try await engine.sendChanges()
      guard self.engine === engine else { return }
      let conflicts = store?.snapshot.records.values.contains { !$0.conflicts.isEmpty } ?? false
      let pending = store?.snapshot.records.values.contains { $0.dirty } ?? false
      store?.setSyncStatus(conflicts ? "Configuration conflict" : pending ? "Changes waiting to sync" : "Synced")
    } catch { store?.setSyncStatus("Sync failed: \(error.localizedDescription)") }
  }

  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    await handle(event, engine: syncEngine)
  }

  private func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) {
    guard self.engine === engine, let store else { return }
    do {
      switch event {
      case .stateUpdate(let update):
        let data = try JSONEncoder().encode(update.stateSerialization)
        try store.update { $0.syncState = data }
      case .accountChange(let change):
        self.engine = nil
        account = nil
        // Invalidate visible sessions before exposing another account's objects.
        try store.switchAccount("local")
        switch change.changeType {
        case .signIn(let user), .switchAccounts(_, let user):
          if let container { try activate(user.recordName, container: container) }
        case .signOut: store.setSyncStatus("Sign in to iCloud to sync")
        @unknown default: store.setSyncStatus("iCloud account changed")
        }
      case .fetchedRecordZoneChanges(let changes):
        for modification in changes.modifications { try receive(modification.record) }
        for deletion in changes.deletions {
          if let id = UUID(uuidString: deletion.recordID.recordName) {
            try store.update { state in
              state.records[id]?.deleted = true
              state.records[id]?.dirty = false
              state.approvals.removeValue(forKey: id)
            }
          }
        }
      case .sentRecordZoneChanges(let changes):
        for record in changes.savedRecords {
          guard let id = UUID(uuidString: record.recordID.recordName),
            let payload = record["profile"] as? Data else { continue }
          let sent = try JSONDecoder().decode(HostProfile.self, from: payload)
          let deleted = (record["deleted"] as? Int64 ?? 0) != 0
          let fields = archive(record)
          try store.update { state in
            guard var current = state.records[id] else { return }
            current.base = sent
            current.systemFields = fields
            current.dirty = current.profile != sent || current.deleted != deleted
            state.records[id] = current
          }
        }
        for failure in changes.failedRecordSaves {
          if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
            try receive(server)
          } else {
            store.setSyncStatus("Sync failed: \(failure.error.localizedDescription)")
          }
        }
        enqueue()
      case .fetchedDatabaseChanges(let changes):
        if changes.deletions.contains(where: { $0.zoneID == zone }) {
          // Do not recreate a remotely removed library from stale offline data.
          try store.update { state in
            for id in state.records.keys { state.records[id]?.deleted = true; state.records[id]?.dirty = false }
            state.approvals = [:]
          }
        }
      case .sentDatabaseChanges(let changes):
        if let failure = changes.failedZoneSaves.first { store.setSyncStatus("Sync failed: \(failure.error.localizedDescription)") }
      default: break
      }
    } catch { store.setSyncStatus("Sync failed: \(error.localizedDescription)") }
  }

  private func receive(_ record: CKRecord) throws {
    guard record.recordType == "TetherHost", let payload = record["profile"] as? Data else { return }
    let profile = try JSONDecoder().decode(HostProfile.self, from: payload)
    guard record.recordID.recordName == profile.id.uuidString else { throw IdentityError.invalidConfiguration }
    try store?.receive(profile, deleted: (record["deleted"] as? Int64 ?? 0) != 0, systemFields: archive(record))
  }

  nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await batch(context, engine: syncEngine)
  }

  private func batch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) -> CKSyncEngine.RecordZoneChangeBatch? {
    guard self.engine === engine, let store, store.scope == account else { return nil }
    do {
      let records = try store.snapshot.records.values.filter { $0.dirty && $0.conflicts.isEmpty }.prefix(100).compactMap { entry -> CKRecord? in
        let id = CKRecord.ID(recordName: entry.profile.id.uuidString, zoneID: zone)
        guard context.options.scope.contains(id) else { return nil }
        let record: CKRecord
        if let data = entry.systemFields {
          let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
          decoder.requiresSecureCoding = true
          defer { decoder.finishDecoding() }
          guard let restored = CKRecord(coder: decoder) else { throw IdentityError.invalidConfiguration }
          record = restored
        } else { record = CKRecord(recordType: "TetherHost", recordID: id) }
        record["profile"] = try JSONEncoder().encode(entry.profile)
        record["deleted"] = Int64(entry.deleted ? 1 : 0)
        return record
      }
      return records.isEmpty ? nil : CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
    } catch { store.setSyncStatus("Sync failed: \(error.localizedDescription)"); return nil }
  }

  private func archive(_ record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }
}
