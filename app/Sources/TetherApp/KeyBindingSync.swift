import CloudKit
import Foundation

/// One revision covers both alternatives. A nil pair is a durable reset, not
/// a missing record: an offline device must not resurrect the old assignment.
struct KeyBindingChange: Codable, Equatable {
  var bindings: [KeyBinding?]?
  var modified: Date
  var token: String

  var isValid: Bool {
    guard modified.timeIntervalSince1970.isFinite, UUID(uuidString: token) != nil else { return false }
    guard let bindings else { return true }
    let assigned = bindings.compactMap { $0 }
    return bindings.count == 2 && assigned.allSatisfy(\.isValid)
      && Set(assigned).count == assigned.count
  }

  func isNewer(than other: Self) -> Bool {
    modified == other.modified ? token > other.token : modified > other.modified
  }
}

struct KeyBindingSyncEntry: Codable {
  var change: KeyBindingChange
  var dirty = true
  var systemFields: Data?
}

struct KeyBindingArchive: Codable {
  var account = "local"
  var accounts: [String: [String: KeyBindingSyncEntry]] = [:]
  var initializedAccounts: Set<String> = []
}

/// CloudKit is confined to this codec and the existing app sync engine. The
/// binding store can merge, persist and test offline without a cloud account.
enum KeyBindingCloudRecords {
  static let zone = CKRecordZone.ID(zoneName: "TetherKeyBindings")
  static let recordType = "TetherKeyBinding"

  static func id(_ command: String) -> CKRecord.ID {
    CKRecord.ID(recordName: command, zoneID: zone)
  }

  static func record(_ command: String, entry: KeyBindingSyncEntry) throws -> CKRecord {
    let record: CKRecord
    if let data = entry.systemFields {
      let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
      decoder.requiresSecureCoding = true
      defer { decoder.finishDecoding() }
      guard let restored = CKRecord(coder: decoder), restored.recordID == id(command),
        restored.recordType == recordType else { throw IdentityError.invalidConfiguration }
      record = restored
    } else {
      record = CKRecord(recordType: recordType, recordID: id(command))
    }
    record["value"] = try JSONEncoder().encode(entry.change)
    return record
  }

  static func change(in record: CKRecord) throws -> KeyBindingChange {
    guard record.recordID.zoneID == zone, record.recordType == recordType,
      !record.recordID.recordName.isEmpty,
      let data = record["value"] as? Data, data.count <= 16_384 else {
      throw IdentityError.invalidConfiguration
    }
    let change = try JSONDecoder().decode(KeyBindingChange.self, from: data)
    guard change.isValid else { throw IdentityError.invalidConfiguration }
    return change
  }

  static func systemFields(_ record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }
}
