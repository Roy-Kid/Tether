import CloudKit
import Foundation
import OSLog
import Security

/// What synchronization did, for Console: event kinds and counts, never a
/// host's contents.
let syncLog = Logger(subsystem: "Tether", category: "sync")

/// CloudKit carries the library for this Apple ID: the host, and the private
/// key that logs into it. Passwords, one-time-code seeds and keychain
/// identifiers stay out of the record. The key field is bytes, never logged.
@MainActor
final class HostCloudSync: CKSyncEngineDelegate {
  private weak var store: HostStore?
  private var engine: CKSyncEngine?
  private var container: CKContainer?
  private var starting = false
  /// An account change that arrived while `start` was still running.
  private var restartRequested = false
  private let zone = CKRecordZone.ID(zoneName: "TetherHosts")
  private var account: String?
  private var failureGeneration = 0
  var continuityDatabase: CKDatabase? { engine == nil ? nil : container?.privateCloudDatabase }

  init(store: HostStore) { self.store = store }

  func start() async {
    guard !starting else { return }
    if engine != nil { return }
    starting = true
    defer {
      starting = false
      if restartRequested {
        restartRequested = false
        Task { await self.start() }
      }
    }
    // Calling CloudKit from an ad-hoc signed binary can raise an Objective-C
    // exception. Inspect the entitlement before creating a container.
    let identifier: String
    #if os(macOS)
    guard let task = SecTaskCreateFromSelf(nil),
      let identifiers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
      let configured = identifiers.first
    else {
      store?.setSyncStatus("iCloud unavailable in this build",
        failure: "This build of Tether is not signed for iCloud.")
      return
    }
    identifier = configured
    #else
    // iOS has no public SecTask entitlement API. A provisioned app build opts in
    // through its Info.plist; simulator/ad-hoc bundles omit this key.
    guard let configured = Bundle.main.object(forInfoDictionaryKey: "TetherCloudContainer") as? String,
      configured.hasPrefix("iCloud.") else {
      store?.setSyncStatus("iCloud unavailable in this build",
        failure: "This build of Tether is not signed for iCloud.")
      return
    }
    identifier = configured
    #endif
    let container = CKContainer(identifier: identifier)
    self.container = container
    do {
      let status = try await container.accountStatus()
      if status == .noAccount {
        try store?.switchAccount("local")
        store?.setSyncStatus("Sign in to iCloud to sync", failure: "Sign in to iCloud in Settings to sync hosts.")
        return
      }
      guard status == .available else {
        store?.setSyncStatus("iCloud temporarily unavailable; using the offline library",
          failure: "iCloud is not available right now. Try again in a moment.")
        return
      }
      let user = try await container.userRecordID()
      try activate(user.recordName, container: container)
      await synchronize()
    } catch { store?.setSyncStatus("Sync failed", failure: error.localizedDescription) }
  }

  private func activate(_ user: String, container: CKContainer) throws {
    guard let store else { return }
    let scope = "icloud:" + user
    try store.switchAccount(scope)
    store.importLocalLibrary()
    account = scope
    // An older app may have advanced past records it did not understand.
    // Read the account in full once when enabling key binding sync.
    let savedState = store.keyBindings?.needsInitialCloudFetch == true ? nil : store.snapshot.syncState
    let state = try savedState.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
      stateSerialization: state, delegate: self)
    // Foreground sync is explicit; automatic sync also runs when the system permits.
    configuration.automaticallySync = true
    engine = CKSyncEngine(configuration)
    if state == nil { engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))]) }
    // Existing installations already have a host sync token. The preferences
    // zone must also be created when upgrading those installations.
    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: KeyBindingCloudRecords.zone))])
    enqueue()
  }

  func enqueue() {
    guard let store, let engine, account == store.scope else { return }
    store.noteKeysAwaitingSync()
    var pending = store.snapshot.records.values.filter { $0.dirty && $0.conflicts.isEmpty }.map {
      CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0.profile.id.uuidString, zoneID: zone))
    }
    let bindingIDs = Set(store.keyBindings?.pending ?? [])
    pending += bindingIDs.map {
      CKSyncEngine.PendingRecordZoneChange.saveRecord(KeyBindingCloudRecords.id($0))
    }
    // Fetching the winning server revision can clean an outbox entry before
    // its queued save is sent. Remove that save from the engine as well.
    engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges.filter {
      if case .saveRecord(let id) = $0, id.zoneID == KeyBindingCloudRecords.zone {
        return !bindingIDs.contains(id.recordName)
      }
      return false
    })
    engine.state.add(pendingRecordZoneChanges: pending)
    if store.syncFailure == nil { store.setSyncStatus(pending.isEmpty ? "Synced" : "Changes waiting to sync") }
  }

  /// Forgets how far this device had read and reads the whole library
  /// again. What a person asking to sync is asking for: every host here, not
  /// what changed since a moment that may have gone wrong — a fetched batch
  /// that could not be applied is not fetched a second time otherwise.
  func resynchronize() async {
    guard let store, engine != nil else {
      await start()
      return
    }
    syncLog.info("reading the whole library again")
    engine = nil
    account = nil
    do { try store.update { $0.syncState = nil } } catch {
      store.setSyncStatus("Sync failed", failure: error.localizedDescription)
      return
    }
    await start()
  }

  func synchronize() async {
    guard let engine else { await start(); return }
    let failures = failureGeneration
    do {
      store?.setSyncStatus("Syncing")
      try await engine.fetchChanges()
      guard self.engine === engine else { return }
      if failures == failureGeneration { store?.keyBindings?.didFetchCloud() }
      enqueue()
      try await engine.sendChanges()
      guard self.engine === engine else { return }
      guard failures == failureGeneration else { return }
      let conflicts = store?.snapshot.records.values.contains { !$0.conflicts.isEmpty } ?? false
      let pending = (store?.snapshot.records.values.contains { $0.dirty } ?? false)
        || !(store?.keyBindings?.pending.isEmpty ?? true)
      store?.setSyncStatus(conflicts ? "Configuration conflict" : pending ? "Changes waiting to sync" : "Synced")
      store?.didSync()
    } catch { if self.engine === engine { failed(error) } }
  }

  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    await handle(event, engine: syncEngine)
  }

  private func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) {
    guard self.engine === engine, let store else { return }
    syncLog.debug("event \(String(describing: event).prefix(40), privacy: .public)")
    do {
      switch event {
      case .stateUpdate(let update):
        let data = try JSONEncoder().encode(update.stateSerialization)
        try store.update { $0.syncState = data }
      case .accountChange(let change):
        try accountChanged(change)
      case .fetchedRecordZoneChanges(let changes):
        syncLog.info("fetched \(changes.modifications.count) changed and \(changes.deletions.count) removed records")
        for modification in changes.modifications { try receive(modification.record) }
        // Tether deletes with a tombstone, never by removing the record, so
        // a record that is simply gone went with something iCloud did.
        let gone = changes.deletions.filter { $0.recordID.zoneID == zone }
          .compactMap { UUID(uuidString: $0.recordID.recordName) }
        if !gone.isEmpty { try store.vanish(gone) }
        let removed = changes.deletions.filter { $0.recordID.zoneID == KeyBindingCloudRecords.zone }
          .map { $0.recordID.recordName }
        store.keyBindings?.removeCloudRecords(removed)
        engine.state.remove(pendingRecordZoneChanges: removed.map { .saveRecord(KeyBindingCloudRecords.id($0)) })
        enqueue()
      case .sentRecordZoneChanges(let changes):
        for record in changes.savedRecords {
          if record.recordID.zoneID == KeyBindingCloudRecords.zone {
            let sent = try KeyBindingCloudRecords.change(in: record)
            store.keyBindings?.didSave(sent, for: record.recordID.recordName,
              systemFields: KeyBindingCloudRecords.systemFields(record))
            continue
          }
          guard let id = UUID(uuidString: record.recordID.recordName),
            let payload = record["profile"] as? Data else { continue }
          let sent = try JSONDecoder().decode(HostProfile.self, from: payload)
          let deleted = (record["deleted"] as? Int64 ?? 0) != 0
          let fields = archive(record)
          let digest = store.sharedPrivateKey(for: sent).map(HostStore.keyDigest)
          try store.update { state in
            guard var current = state.records[id] else { return }
            current.base = sent
            current.systemFields = fields
            current.dirty = current.profile != sent || current.deleted != deleted
            if current.forgetSharedKey == true {
              current.forgetSharedKey = nil
              current.syncedKeyDigest = HostStore.clearedKey
            } else if let digest {
              current.syncedKeyDigest = digest
            }
            state.records[id] = current
          }
        }
        for failure in changes.failedRecordSaves {
          if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
            try receive(server)
          } else if failure.record.recordID.zoneID == KeyBindingCloudRecords.zone,
            failure.error.code == .zoneNotFound || failure.error.code == .unknownItem {
            if failure.error.code == .zoneNotFound {
              store.keyBindings?.prepareReupload()
              engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: KeyBindingCloudRecords.zone))])
            } else {
              store.keyBindings?.retryMissingRecord(failure.record.recordID.recordName)
            }
          } else {
            failed(failure.error)
          }
        }
        enqueue()
      case .fetchedDatabaseChanges(let changes):
        syncLog.info("fetched \(changes.modifications.count) changed and \(changes.deletions.count) removed zones")
        for deletion in changes.deletions where deletion.zoneID == zone {
          if deletion.reason == .encryptedDataReset {
            // Nothing was meant to be deleted; the zone's encryption was
            // reset. Put this device's copy back.
            try store.prepareReupload()
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
            enqueue()
          } else {
            // Deleted or purged on purpose: do not recreate the library from
            // stale offline data.
            try store.vanish()
          }
        }
        for deletion in changes.deletions where deletion.zoneID == KeyBindingCloudRecords.zone {
          if deletion.reason == .encryptedDataReset {
            store.keyBindings?.prepareReupload()
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: KeyBindingCloudRecords.zone))])
            enqueue()
          } else {
            let ids = store.keyBindings.map { Array($0.entries.keys) } ?? []
            store.keyBindings?.removeCloudRecords(ids)
            engine.state.remove(pendingRecordZoneChanges: ids.map { .saveRecord(KeyBindingCloudRecords.id($0)) })
          }
        }
      case .sentDatabaseChanges(let changes):
        if let failure = changes.failedZoneSaves.first { failed(failure.error) }
      default: break
      }
    } catch { failed(error) }
  }

  /// A sync engine introduces itself with a sign-in to the account it
  /// started under, so a sign-in to the account already active is not a
  /// change. Anything else retires this engine, and its successor is built
  /// after this callback returns: constructing a `CKSyncEngine` inside its
  /// predecessor's delegate call deadlocks CloudKit's queue, and the system
  /// kills the app for it.
  private func accountChanged(_ change: CKSyncEngine.Event.AccountChange) throws {
    guard let store else { return }
    if case .signIn(let user) = change.changeType, "icloud:" + user.recordName == account { return }
    engine = nil
    account = nil
    // Invalidate visible sessions before exposing another account's objects.
    try store.switchAccount("local")
    if case .signOut = change.changeType {
      store.setSyncStatus("Sign in to iCloud to sync", failure: "Sign in to iCloud in Settings to sync hosts.")
    } else if starting {
      restartRequested = true
    } else {
      Task { await self.start() }
    }
  }

  private func receive(_ record: CKRecord) throws {
    if record.recordID.zoneID == KeyBindingCloudRecords.zone {
      try store?.keyBindings?.receive(KeyBindingCloudRecords.change(in: record),
        for: record.recordID.recordName, systemFields: KeyBindingCloudRecords.systemFields(record))
      return
    }
    guard record.recordType == "TetherHost", let payload = record["profile"] as? Data else { return }
    let profile = try JSONDecoder().decode(HostProfile.self, from: payload)
    guard record.recordID.recordName == profile.id.uuidString else { throw IdentityError.invalidConfiguration }
    let privateKey: String?
    if let data = record["privateKey"] as? Data {
      privateKey = String(data: data, encoding: .utf8) ?? ""
    } else {
      privateKey = nil
    }
    try store?.receive(profile, deleted: (record["deleted"] as? Int64 ?? 0) != 0, systemFields: archive(record),
      privateKey: privateKey)
  }

  nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await batch(context, engine: syncEngine)
  }

  private func batch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) -> CKSyncEngine.RecordZoneChangeBatch? {
    guard self.engine === engine, let store, store.scope == account else { return nil }
    do {
      var records = try store.snapshot.records.values.filter { $0.dirty && $0.conflicts.isEmpty }.prefix(100).compactMap { entry -> CKRecord? in
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
        if entry.forgetSharedKey == true {
          record["privateKey"] = Data()
        } else if let pem = store.sharedPrivateKey(for: entry.profile) {
          record["privateKey"] = Data(pem.utf8)
        }
        return record
      }
      if let bindings = store.keyBindings {
        for id in bindings.pending where context.options.scope.contains(KeyBindingCloudRecords.id(id)) {
          if records.count >= 100 { break }
          if let entry = bindings.entries[id] { records.append(try KeyBindingCloudRecords.record(id, entry: entry)) }
        }
      }
      return records.isEmpty ? nil : CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
    } catch { failed(error); return nil }
  }

  private func failed(_ error: Error) {
    failureGeneration += 1
    store?.setSyncStatus("Sync failed", failure: error.localizedDescription)
  }

  private func archive(_ record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }
}
