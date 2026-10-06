import Foundation
import Tether

/// Disk retention is independent of the terminal's bounded memory cache.
enum HistoryPreference {
  static let linesKey = "sessionHistoryLines"
  static let unlimitedKey = "sessionHistoryUnlimited"
  static let defaultLines = 10_000

  static func limit(in defaults: UserDefaults = .standard) -> UInt64? {
    if defaults.bool(forKey: unlimitedKey) { return nil }
    let value = defaults.object(forKey: linesKey) as? Int ?? defaultLines
    return UInt64(max(1, value))
  }
}

/// The app owns the archive directory and which sessions are retained. The
/// SDK owns terminal content; credentials never enter this manifest.
@MainActor
final class SessionHistoryStore {
  struct Manifest: Codable, Equatable {
    var version = 2
    var closed: [ClosedTerminal]
    var open: [ClosedTerminal]
  }

  let directory: URL
  private var lastSaved: Manifest?
  private(set) var problem: String?
  private(set) var canWrite = true

  init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "Tether/SessionHistory", directoryHint: .isDirectory)) {
    self.directory = directory
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var local = directory
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try local.setResourceValues(values)
    } catch { problem = error.localizedDescription; canWrite = false }
  }

  func location(_ id: UUID) -> URL { directory.appending(path: id.uuidString, directoryHint: .isDirectory) }

  func load() -> [ClosedTerminal] {
    let path = directory.appending(path: "tabs.json")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    do {
      let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: path))
      guard (1...2).contains(manifest.version) else { throw CocoaError(.fileReadCorruptFile) }
      for record in manifest.open + manifest.closed {
        guard let layout = record.layout else { continue }
        let panes = Set((record.panes ?? []).map(\.id))
        guard record.panes != nil, record.panes?.count == panes.count, layout.isValid(panes: panes),
          record.focusedPane.map({ panes.contains($0) }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
      }
      lastSaved = manifest
      // Open sessions left by an exit/crash are recoverable too. Nothing is
      // reconnected until the person asks to restore a tab.
      return Array((manifest.closed + manifest.open).suffix(TabSet.closedTabLimit))
    } catch {
      problem = error.localizedDescription
      canWrite = false
      return []
    }
  }

  func save(open: [ClosedTerminal], closed: [ClosedTerminal], retaining: Set<UUID> = []) {
    guard canWrite else { return }
    let manifest = Manifest(closed: closed, open: open)
    guard manifest != lastSaved else { return }
    do {
      let data = try JSONEncoder().encode(manifest)
      let path = directory.appending(path: "tabs.json")
      try data.write(to: path, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      lastSaved = manifest
      let retained = Set((open + closed).flatMap { [$0] + ($0.panes ?? []) }.compactMap(\.historyID)).union(retaining)
      for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        if let id = UUID(uuidString: child.lastPathComponent), !retained.contains(id) {
          try FileManager.default.removeItem(at: child)
        }
      }
    } catch { problem = error.localizedDescription }
  }
}
