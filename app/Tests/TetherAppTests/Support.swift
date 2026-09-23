import Foundation
import SwiftUI
import Tether
import TetherPluginKit

@testable import TetherApp

// `Foundation` exports a `Host` of its own, and qualifying by module name does
// not help here — the app's `@main` type is also called `TetherApp`. Importing
// the one type by name settles it.
import struct TetherApp.Host

/// A keychain a test can have.
///
/// The real one is the system's, and nothing here may reach it: a unit test
/// that asks for the login keychain gets a prompt on a developer's machine and
/// a refusal on a build server, which is how a keychain test becomes a deleted
/// keychain test. So no test in this target constructs `Keychain` — every one
/// of them passes this instead, including to `HostStore`, whose default
/// argument would otherwise be the real thing.
///
/// `Keychain` itself is the one part only the system can answer for, and it is
/// exercised by running the app, never by CI.
final class MemorySecrets: SecretStore, @unchecked Sendable {
  private struct Item {
    var password: String
    var label: String
  }

  private let lock = NSLock()
  private var items: [UUID: Item] = [:]
  /// Set to make every call fail, which is the branch a real keychain takes
  /// when it is locked and the one nothing would otherwise cover.
  var refusing = false

  func password(for host: UUID) throws -> String? {
    try refuse()
    return lock.withLock { items[host]?.password }
  }

  func remember(_ password: String, for host: Host) throws {
    try refuse()
    lock.withLock { items[host.id] = Item(password: password, label: "Tether — \(host.address)") }
  }

  func forget(_ host: UUID) throws {
    try refuse()
    _ = lock.withLock { items.removeValue(forKey: host) }
  }

  func saved() throws -> [SavedSecret] {
    try refuse()
    return lock.withLock {
      items.map { SavedSecret(id: $0.key, label: $0.value.label) }
        .sorted { $0.label < $1.label }
    }
  }

  private func refuse() throws {
    if refusing { throw SecretError.refused(errSecInteractionNotAllowed) }
  }
}

/// A file path in a directory that goes away with the test.
///
/// Every store here writes JSON, and a test that shared a location with the
/// app would read someone's real hosts and then overwrite them.
func temporaryFile(_ name: String) -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "tether-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appending(path: name)
}

func removeDirectory(of file: URL) {
  try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
}

/// A workspace an extension could have opened, with no extension behind it.
///
/// The host owns a workspace's tab and its lifetime, and that ownership is
/// what these tests are about — so the thing being owned can be this.
@MainActor
final class StubWorkspace: PluginWorkspace {
  let id = UUID()
  let title: String
  let subtitle = ""
  let symbol = "puzzlepiece.extension"
  var commands: [PluginCommand] { [] }
  private(set) var closed = false

  init(title: String) { self.title = title }

  func content() -> AnyView { AnyView(EmptyView()) }
  func inspector() -> AnyView { AnyView(EmptyView()) }
  func close() { closed = true }
}

/// What a tab plugin keeps on a tab, with no plugin behind it.
///
/// The host draws what an attachment reports and forwards the tab's
/// lifetime to it; that is what these tests are about, so the attachment
/// can report whatever the test sets.
@MainActor
final class StubAttachment: TabAttachment {
  var isShowing = false
  var subtitle: String
  var isDisconnected = false
  var closeNote: String?
  var commands: [PluginCommand] { [] }
  private(set) var closed = false

  init(subtitle: String = "", closeNote: String? = nil) {
    self.subtitle = subtitle
    self.closeNote = closeNote
  }

  func content() -> AnyView { AnyView(EmptyView()) }
  func inspector() -> AnyView { AnyView(EmptyView()) }
  func accessoryContent() -> AnyView { AnyView(EmptyView()) }
  func connectionChanged(_ connection: RemoteConnection) {}
  func close() { closed = true }
}
