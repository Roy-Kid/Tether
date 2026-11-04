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
      #expect(b.bindings(for: command) == [nil, command.defaults[1]])
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

}
