import CloudKit
import Foundation
import Testing
@testable import TetherApp

@MainActor
@Suite("Key binding sync")
struct KeyBindingSyncTests {
  private let first = KeyBindingCommand(id: "test.first", title: "First", group: "Test")
  private let second = KeyBindingCommand(id: "test.second", title: "Second", group: "Test")
  private var commands: [KeyBindingCommand] { [first, second] }

  private func isolated(_ body: (KeyBindingStore, KeyBindingStore, UserDefaults, UserDefaults) throws -> Void) rethrows {
    let names = ("binding-sync-a.\(UUID())", "binding-sync-b.\(UUID())")
    let a = UserDefaults(suiteName: names.0)!, b = UserDefaults(suiteName: names.1)!
    defer { a.removePersistentDomain(forName: names.0); b.removePersistentDomain(forName: names.1) }
    let left = KeyBindingStore(defaults: a), right = KeyBindingStore(defaults: b)
    left.register(commands); right.register(commands)
    try body(left, right, a, b)
  }

  private func change(_ key: String?, time: Double = 100, token: Int = 1) -> KeyBindingChange {
    KeyBindingChange(bindings: key.map { [KeyBinding($0, .control), nil] },
      modified: Date(timeIntervalSince1970: time),
      token: String(format: "00000000-0000-0000-0000-%012d", token))
  }

  /// Exercise exactly the record codec used by the sync engine, without
  /// accessing any Apple account or changing the CloudKit schema in tests.
  private func deliver(_ source: KeyBindingStore, to target: KeyBindingStore) throws {
    for (id, entry) in source.entries {
      let record = try KeyBindingCloudRecords.record(id, entry: entry)
      try target.receive(KeyBindingCloudRecords.change(in: record), for: id,
        systemFields: KeyBindingCloudRecords.systemFields(record))
    }
  }

  @Test("different commands and both alternatives survive merging in either direction")
  func independentEdits() throws {
    try isolated { a, b, _, _ in
      try a.set(KeyBinding("a", .control), for: first, slot: 0, commands: commands)
      try a.set(KeyBinding("a", .option), for: first, slot: 1, commands: commands)
      try b.set(KeyBinding("b", .control), for: second, slot: 1, commands: commands)
      try deliver(a, to: b)
      try deliver(b, to: a)
      #expect(a.overrides == b.overrides)
      #expect(a.bindings(for: first) == [KeyBinding("a", .control), KeyBinding("a", .option)])
      #expect(a.bindings(for: second) == [nil, KeyBinding("b", .control)])
    }
  }

  @Test("same-command edits converge by time and a stable tie breaker")
  func concurrentEdits() throws {
    try isolated { a, b, _, _ in
      let older = change("a"), newer = change("b", token: 2)
      try a.receive(older, for: first.id, systemFields: nil)
      try a.receive(newer, for: first.id, systemFields: nil)
      try b.receive(newer, for: first.id, systemFields: nil)
      try b.receive(older, for: first.id, systemFields: nil)
      #expect(a.overrides == b.overrides)
      #expect(b.entries[first.id]?.change == newer)
      #expect(b.pending == [first.id], "an older server revision leaves the winner queued for retry")
      try b.receive(newer, for: first.id, systemFields: nil)
      #expect(b.pending.isEmpty)
    }
  }

  @Test("clear and reset are distinct and a stale device cannot resurrect a reset")
  func resetAndClear() throws {
    try isolated { a, b, _, defaults in
      let command = WorkspaceAction.newTerminal.command
      try a.set(nil, for: command, slot: 0, commands: [command])
      try deliver(a, to: b)
      #expect(b.bindings(for: command) == [nil, nil])
      let stale = try #require(b.entries[command.id]?.change)
      try a.reset(command, commands: [command])
      try deliver(a, to: b)
      #expect(b.bindings(for: command) == command.defaults)
      #expect(b.entries[command.id]?.change.bindings == nil)
      try b.receive(stale, for: command.id, systemFields: nil)
      #expect(b.bindings(for: command) == command.defaults)
      let restarted = KeyBindingStore(defaults: defaults)
      #expect(restarted.bindings(for: command) == command.defaults)
      #expect(restarted.pending == [command.id])
    }
  }

  @Test("an in-flight acknowledgement preserves newer edits and survives relaunch")
  func outbox() throws {
    try isolated { a, _, defaults, _ in
      try a.set(KeyBinding("a", .control), for: first, slot: 0, commands: commands)
      let sent = try #require(a.entries[first.id]?.change)
      let record = try KeyBindingCloudRecords.record(first.id, entry: try #require(a.entries[first.id]))
      let fields = KeyBindingCloudRecords.systemFields(record)
      try a.set(KeyBinding("b", .control), for: first, slot: 1, commands: commands)
      a.didSave(sent, for: first.id, systemFields: fields)
      let restarted = KeyBindingStore(defaults: defaults)
      #expect(restarted.pending == [first.id])
      #expect(restarted.requestedBindings(for: first) == [KeyBinding("a", .control), KeyBinding("b", .control)])
      restarted.didSave(try #require(restarted.entries[first.id]?.change), for: first.id, systemFields: fields)
      #expect(KeyBindingStore(defaults: defaults).pending.isEmpty)
    }
  }

  @Test("an empty installation publishes nothing and accepts existing cloud bindings")
  func emptyInstall() throws {
    try isolated { a, b, _, _ in
      b.switchAccount("icloud:A")
      #expect(b.pending.isEmpty)
      try a.set(KeyBinding("x", .control), for: first, slot: 0, commands: commands)
      try deliver(a, to: b)
      #expect(b.requestedBindings(for: first) == a.requestedBindings(for: first))
      #expect(b.pending.isEmpty)
    }
  }

  @Test("legacy overrides migrate once, with existing cloud values taking precedence")
  func legacyMigration() throws {
    try isolated { _, _, defaults, _ in
      defaults.set(try JSONEncoder().encode([
        first.id: [KeyBinding("a", .control), nil],
        second.id: [nil, KeyBinding("b", .control)],
      ]), forKey: KeyBindingStore.preferenceKey)
      let store = KeyBindingStore(defaults: defaults)
      store.switchAccount("icloud:A")
      try store.receive(change("c"), for: first.id, systemFields: nil)
      #expect(store.requestedBindings(for: first) == [KeyBinding("c", .control), nil])
      #expect(store.requestedBindings(for: second) == [nil, KeyBinding("b", .control)])
      #expect(store.pending == [second.id])
      store.switchAccount("icloud:B")
      #expect(store.overrides.isEmpty)
      store.switchAccount("icloud:A")
      #expect(store.overrides.count == 2)
      #expect(KeyBindingStore(defaults: defaults).account == "icloud:A")
    }
  }

  @Test("account switching isolates cloud libraries and moves signed-out edits only once")
  func accounts() throws {
    try isolated { a, _, defaults, _ in
      try a.set(KeyBinding("a", .control), for: first, slot: 0, commands: commands)
      a.switchAccount("icloud:A")
      a.switchAccount("local")
      #expect(a.overrides.isEmpty)
      try a.set(KeyBinding("b", .control), for: second, slot: 0, commands: commands)
      a.switchAccount("icloud:B")
      #expect(a.overrides[first.id] == nil)
      #expect(a.overrides[second.id] != nil)
      a.switchAccount("icloud:A")
      #expect(a.overrides[first.id] != nil)
      #expect(a.overrides[second.id] == nil)
      let restarted = KeyBindingStore(defaults: defaults)
      #expect(restarted.account == "icloud:A")
      #expect(restarted.overrides == a.overrides)
    }
  }

  @Test("cross-command conflicts converge, keep both edits, and dispatch only the winner")
  func duplicateAssignments() throws {
    try isolated { a, b, _, _ in
      let older = change("x"), newer = change("x", time: 200)
      try a.receive(older, for: first.id, systemFields: nil)
      try b.receive(newer, for: second.id, systemFields: nil)
      try deliver(a, to: b)
      try deliver(b, to: a)
      for store in [a, b] {
        #expect(store.command(for: KeyBinding("x", .control), in: commands) == second.id)
        #expect(store.bindings(for: first) == [nil, nil])
        #expect(store.requestedBindings(for: first) == older.bindings)
        #expect(store.conflict(for: first, slot: 0) != nil)
        #expect(store.conflict(for: second, slot: 0) == nil)
      }
      try a.set(nil, for: first, slot: 0, commands: commands)
      try deliver(a, to: b)
      #expect(b.conflict(for: first, slot: 0) == nil)
    }
  }

  @Test("a synced custom assignment wins over a default, including absent plugins")
  func defaultCollision() throws {
    try isolated { a, _, _, _ in
      let command = WorkspaceAction.newTerminal.command
      var custom = change("n")
      custom.bindings = [KeyBinding("n"), nil]
      try a.receive(custom, for: "plugin.absent.command.run", systemFields: nil)
      #expect(a.bindings(for: command)[0] == nil)
      #expect(a.conflict(for: command, slot: 0) != nil)
      #expect(a.command(for: KeyBinding("n"), in: [command]) == nil)
      a.removeCloudRecords(["plugin.absent.command.run"])
      #expect(a.bindings(for: command) == command.defaults)
    }
  }

  @Test("invalid cloud values are rejected atomically")
  func invalidRecords() throws {
    try isolated { a, _, _, _ in
      try a.receive(change("x"), for: first.id, systemFields: nil)
      var invalid = change("y", time: 500)
      invalid.bindings = [KeyBinding("y", [])]
      #expect(throws: (any Error).self) { try a.receive(invalid, for: first.id, systemFields: nil) }
      invalid.bindings = [KeyBinding("y", .control), KeyBinding("y", .control)]
      #expect(throws: (any Error).self) { try a.receive(invalid, for: first.id, systemFields: nil) }
      let record = try KeyBindingCloudRecords.record(first.id, entry: KeyBindingSyncEntry(change: invalid))
      #expect(throws: (any Error).self) { try KeyBindingCloudRecords.change(in: record) }
      #expect(a.requestedBindings(for: first) == [KeyBinding("x", .control), nil])
    }
  }

  @Test("cloud reset reuploads retained values, cloud purge discards only the current account")
  func cloudReset() throws {
    try isolated { a, _, _, _ in
      a.switchAccount("icloud:A")
      try a.receive(change("a"), for: first.id, systemFields: Data([1]))
      a.prepareReupload()
      #expect(a.pending == [first.id])
      #expect(a.entries[first.id]?.systemFields == nil)
      a.switchAccount("icloud:B")
      try a.receive(change("b"), for: second.id, systemFields: nil)
      a.removeCloudRecords([second.id])
      #expect(a.entries.isEmpty)
      a.switchAccount("icloud:A")
      #expect(a.overrides[first.id] != nil)
    }
  }

  @Test("the record codec keeps record identity and restores server metadata")
  func recordCodec() throws {
    let value = change("x")
    let record = try KeyBindingCloudRecords.record(first.id, entry: KeyBindingSyncEntry(change: value))
    #expect(try KeyBindingCloudRecords.change(in: record) == value)
    let restored = try KeyBindingCloudRecords.record(first.id,
      entry: KeyBindingSyncEntry(change: value, systemFields: KeyBindingCloudRecords.systemFields(record)))
    #expect(restored.recordID == record.recordID)
    #expect(try KeyBindingCloudRecords.change(in: restored) == value)
    let wrong = CKRecord(recordType: "TetherHost", recordID: KeyBindingCloudRecords.id(first.id))
    wrong["value"] = try JSONEncoder().encode(value)
    #expect(throws: (any Error).self) { try KeyBindingCloudRecords.change(in: wrong) }
  }

  @Test("host account transitions switch the attached binding store immediately")
  func hostLifecycle() throws {
    try isolated { bindings, _, _, _ in
      let location = temporaryFile("config")
      defer { removeDirectory(of: location) }
      let hosts = HostStore(location: location, secrets: MemorySecrets(),
        credentials: DeviceCredentialStore(secrets: MemorySecrets()))
      hosts.useKeyBindings(bindings)
      try bindings.set(KeyBinding("x", .control), for: first, slot: 0, commands: commands)
      try hosts.switchAccount("icloud:A")
      #expect(bindings.account == "icloud:A")
      #expect(bindings.overrides[first.id] != nil)
      try hosts.switchAccount("icloud:B")
      #expect(bindings.account == "icloud:B")
      #expect(bindings.overrides.isEmpty)
      try hosts.switchAccount("icloud:A")
      #expect(bindings.overrides[first.id] != nil)
    }
  }

  @Test("upgrades require a successful full fetch once per account")
  func firstFetch() throws {
    isolated { a, _, defaults, _ in
      a.switchAccount("icloud:A")
      #expect(a.needsInitialCloudFetch)
      #expect(KeyBindingStore(defaults: defaults).needsInitialCloudFetch)
      a.didFetchCloud()
      #expect(!KeyBindingStore(defaults: defaults).needsInitialCloudFetch)
      a.switchAccount("icloud:B")
      #expect(a.needsInitialCloudFetch)
      a.switchAccount("icloud:A")
      #expect(!a.needsInitialCloudFetch)
    }
  }

  @Test("local edits queue a sync, remote delivery does not echo, reset-all keeps tombstones")
  func schedulingAndResetAll() throws {
    try isolated { a, _, defaults, _ in
      var queued = 0
      a.onChange = { queued += 1 }
      try a.receive(change("x"), for: first.id, systemFields: nil)
      #expect(queued == 0)
      try a.set(KeyBinding("y", .control), for: second, slot: 0, commands: commands)
      #expect(queued == 1)
      a.resetAll()
      #expect(queued == 3)
      #expect(a.overrides.isEmpty)
      #expect(a.pending == [first.id, second.id])
      let restarted = KeyBindingStore(defaults: defaults)
      #expect(restarted.entries.count == 2)
      #expect(restarted.entries.values.allSatisfy { $0.change.bindings == nil })
    }
  }
}
