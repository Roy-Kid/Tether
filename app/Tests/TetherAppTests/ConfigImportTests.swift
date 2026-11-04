import Foundation
import Testing

@testable import TetherApp

/// A Mac's SSH configuration feeding the one library.
///
/// What these pin: a new stanza is added, an edited stanza updates its host,
/// a stanza nobody touched never undoes a change made in Tether, and taking a
/// stanza out of the file takes nothing out of the library.
@Suite("Config import")
struct ConfigImportTests {
  static let config = "/Users/ada/.ssh/config"

  static func entry(_ alias: String = "lab", host: String = "10.0.0.4") -> SSHConfig.Entry {
    SSHConfig.Entry(alias: alias, hostName: host, user: "ada", port: nil, identityFile: nil, file: config)
  }

  static func record(_ label: String = "lab", host: String = "10.0.0.4", modified: Date? = nil,
    deleted: Bool = false) -> SharedHostRecord {
    var profile = HostStore.newProfile(id: UUID(), label: label, hostname: host, username: "ada", port: 22, key: false)
    profile.modified = modified
    var record = SharedHostRecord(profile: profile)
    record.deleted = deleted
    return record
  }

  static func face(_ host: String = "10.0.0.4", name: String = "lab") -> HostFace {
    HostFace(name: name, hostName: host, user: "ada", port: 22)
  }

  static func link(_ record: SharedHostRecord, seen: HostFace? = face()) -> ImportLink {
    ImportLink(id: record.profile.id, file: config, seen: seen)
  }

  static func plan(_ entries: [SSHConfig.Entry], _ records: [SharedHostRecord] = [],
    links: [String: ImportLink] = [:], modified: Date? = nil) -> [ConfigImport.Step] {
    ConfigImport.plan(.init(
      entries: entries, modified: modified.map { [config: $0] } ?? [:],
      records: Dictionary(uniqueKeysWithValues: records.map { ($0.profile.id, $0) }),
      links: links, defaultUser: "ada"))
  }

  @Test("both changed: the one changed last wins")
  func crossedEdits() {
    let now = Date()
    let older = Self.record(host: "10.0.0.9", modified: now.addingTimeInterval(-60))
    #expect(Self.plan([Self.entry()], [older], links: ["lab": Self.link(older, seen: Self.face("10.0.0.1"))], modified: now)
      == [.take(Self.entry(), id: older.profile.id, replacing: nil)])
    let newer = Self.record(host: "10.0.0.9", modified: now)
    #expect(Self.plan([Self.entry()], [newer], links: ["lab": Self.link(newer, seen: Self.face("10.0.0.1"))],
      modified: now.addingTimeInterval(-60)) == [.keep(Self.entry(), id: newer.profile.id)])
  }

  /// Deleted in Tether, and the stanza still in the file: it stays deleted —
  /// until someone edits the stanza, which is asking for the host again.
  @Test("a host deleted in Tether is not brought back by its stanza")
  func deletedInTether() {
    let record = Self.record(deleted: true)
    #expect(Self.plan([Self.entry()], [record], links: ["lab": Self.link(record)]).isEmpty)
    let edited = Self.entry(host: "10.0.0.9")
    #expect(Self.plan([edited], [record], links: ["lab": Self.link(record)]) == [.forget(alias: "lab"), .add(edited)])
  }

  @Test("a host iCloud removed comes back from the file")
  func vanished() {
    var record = Self.record(deleted: true)
    record.vanished = true
    #expect(Self.plan([Self.entry()], [record], links: ["lab": Self.link(record)]) == [.forget(alias: "lab"), .add(Self.entry())])
  }
}
