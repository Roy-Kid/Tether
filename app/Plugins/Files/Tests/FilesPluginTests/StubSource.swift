import Foundation
import Tether

@testable import FilesPlugin

/// A far side made of a dictionary: every path it knows, and whether each is
/// a directory. Records what it was asked to do.
final class StubSource: FileSource, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [String: FileKind]
  private(set) var uploads: [(String, String, Bool)] = []
  private(set) var removedTrees: [String] = []
  private(set) var removed: [String] = []
  private(set) var renames: [(String, String, Bool)] = []
  private(set) var closed = false
  /// Every `stat`, in order. A name filter must not add to it.
  private var recordedStats: [String] = []
  private var recordedLists: [String] = []
  var lists: [String] { lock.withLock { recordedLists } }
  var stats: [String] { lock.withLock { recordedStats } }
  var homePath = "/home/ada"
  var isLocal = false
  /// Modification time `stat` and `list` report, when a test has changed it.
  var modifiedAt: [String: UInt64] = [:]
  /// Held for the length of a listing, so a test can overtake it.
  var listDelay: [String: Duration] = [:]
  /// Held for the length of every download; cancelling the task ends it.
  var downloadDelay: Duration?
  /// Destinations a download finished writing. A move out of the cache does
  /// not add to this.
  private var recordedDownloads: [String] = []
  var downloads: [String] { lock.withLock { recordedDownloads } }

  init(_ files: [String: FileKind]) { self.files = files }

  func home() async throws -> String { homePath }

  func list(_ directory: String) async throws -> [FileEntry] {
    lock.withLock { recordedLists.append(directory) }
    if let delay = lock.withLock({ listDelay[directory] }) { try await Task.sleep(for: delay) }
    return try lock.withLock {
      guard files[directory] == .directory else { throw FileError.notFound(path: directory) }
      let prefix = directory == "/" ? "/" : directory + "/"
      return files.keys
        .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") && $0 != directory }
        .map { entry($0) }
    }
  }

  func stat(_ path: String) async throws -> FileEntry {
    try lock.withLock {
      recordedStats.append(path)
      guard files[path] != nil else { throw FileError.notFound(path: path) }
      return entry(path)
    }
  }
  func lstat(_ path: String) async throws -> FileEntry { try known(path) }

  private func known(_ path: String) throws -> FileEntry {
    try lock.withLock {
      guard files[path] != nil else { throw FileError.notFound(path: path) }
      return entry(path)
    }
  }

  func download(_ path: String, to destination: String, progress: (@Sendable (UInt64) -> Void)?)
    async throws -> UInt64
  {
    if let delay = downloadDelay {
      progress?(1)
      try await Task.sleep(for: delay)
    }
    try Data(path.utf8).write(to: URL(fileURLWithPath: destination))
    progress?(UInt64(path.utf8.count))
    lock.withLock { recordedDownloads.append(destination) }
    return UInt64(path.utf8.count)
  }

  func upload(
    _ source: String, to path: String, replacing: Bool, progress: (@Sendable (UInt64) -> Void)?
  ) async throws -> UInt64 {
    try lock.withLock {
      if files[path] != nil && !replacing { throw FileError.exists(path: path) }
      files[path] = .file
      uploads.append((source, path, replacing))
    }
    return 1
  }

  func makeDirectory(_ path: String) async throws {
    try lock.withLock {
      if files[path] != nil { throw FileError.exists(path: path) }
      files[path] = .directory
    }
  }

  func rename(_ from: String, to: String, replacing: Bool) async throws {
    try lock.withLock {
      if files[to] != nil && !replacing { throw FileError.exists(path: to) }
      files[to] = files.removeValue(forKey: from)
      renames.append((from, to, replacing))
    }
  }

  func remove(_ path: String) async throws {
    lock.withLock {
      files[path] = nil
      removed.append(path)
    }
  }

  func removeTree(_ path: String) async throws -> UInt64 {
    lock.withLock {
      let doomed = files.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
      doomed.forEach { files[$0] = nil }
      removedTrees.append(path)
      return UInt64(doomed.count)
    }
  }

  func close() async { lock.withLock { closed = true } }

  func has(_ path: String) -> Bool { lock.withLock { files[path] != nil } }

  private func entry(_ path: String) -> FileEntry {
    FileEntry(
      name: String(path.split(separator: "/").last ?? "/"), path: path,
      kind: files[path] ?? .other, size: 3, modified: modifiedAt[path] ?? 1_700_000_000,
      permissions: 0o644)
  }
}
