import Foundation
import SQLite3

/// SQLite transactions commit configuration, local bindings and the outbox together.
/// The database is owned by the main actor; CloudKit callbacks hop to that actor.
@MainActor
final class IdentityDatabase {
  private var handle: OpaquePointer?
  let location: URL
  init(location: URL) throws {
    self.location = location
    try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard sqlite3_open_v2(location.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
      if let handle { sqlite3_close(handle) }
      handle = nil
      throw IdentityError.storage("Could not open the identity database.")
    }
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA synchronous=FULL")
    try execute("CREATE TABLE IF NOT EXISTS state (scope TEXT PRIMARY KEY, value BLOB NOT NULL)")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
  }
  isolated deinit { if let handle { sqlite3_close(handle) } }

  func read<T: Decodable>(_ type: T.Type, scope: String) throws -> T? {
    let statement = try prepare("SELECT value FROM state WHERE scope=?")
    defer { sqlite3_finalize(statement) }
    bind(scope, at: 1, in: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
    return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
  }

  func write<T: Encodable>(_ value: T, scope: String) throws {
    let data = try JSONEncoder().encode(value)
    try execute("BEGIN IMMEDIATE")
    do {
      let statement = try prepare("INSERT INTO state(scope,value) VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET value=excluded.value")
      defer { sqlite3_finalize(statement) }
      bind(scope, at: 1, in: statement)
      let bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
      guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
  private func bind(_ text: String, at index: Int32, in statement: OpaquePointer) {
    _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
  }
  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
    return statement
  }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }
  private func failure() -> IdentityError { .storage("Could not persist identity data (SQLite \(sqlite3_errcode(handle))).") }
}

struct IdentitySnapshot: Codable {
  var records: [UUID: SharedHostRecord] = [:]
  var bindings: [UUID: LocalCredentialBinding] = [:]
  var approvals: [UUID: String] = [:]
  var passwordBindings: [UUID: UUID] = [:]
  var adoptedAliases: [String: UUID] = [:]
  var syncState: Data?
  var trust = DeviceTrustState()
  var authorizations: [UUID: RemoteAuthorization] = [:]
}
