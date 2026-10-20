import Foundation

/// Where copies of remote files live on this machine, what they are called,
/// and when they go. One place, so the browser has one answer to each.
///
/// Two roots, by whether losing a copy loses anything:
///
/// - **Disposable** — previews, loading placeholders, files on their way up.
///   This account's own temporary directory (`$TMPDIR` on a Mac, the sandbox's
///   on a phone): nobody else on the machine can read it, and anything in it
///   can be fetched again.
/// - **Editing** — a file opened to be edited, which until it is written back
///   holds the only copy of someone's changes. Application Support, which the
///   system never empties; only the editing copies themselves remove it.
///
/// Every directory made here is `0700` and every copy `0600`: they are the
/// far side's data, and only this account may read them.
enum LocalCopies {
  static var disposable: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Tether", isDirectory: true)
  }

  static var editing: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Tether", isDirectory: true)
      .appendingPathComponent("Editing", isDirectory: true)
  }

  /// Under the disposable root: previews by host, placeholders shown while a
  /// preview loads, and files received to be uploaded.
  static func previews(in base: URL = disposable) -> URL { base.appendingPathComponent("Previews", isDirectory: true) }
  static func loading(in base: URL = disposable) -> URL { base.appendingPathComponent("Loading", isDirectory: true) }
  static func staging(in base: URL = disposable) -> URL { base.appendingPathComponent("Staging", isDirectory: true) }

  /// A preview not looked at for this long goes.
  static let previewAge: TimeInterval = 24 * 60 * 60
  /// What all hosts' previews together may hold.
  static let previewLimit: Int64 = 1024 * 1024 * 1024
  /// A placeholder or a received file still here after this was left behind
  /// by a run that ended early.
  static let leftoverAge: TimeInterval = 60 * 60

  /// Makes `url` and any missing parent, closed to every other account.
  @discardableResult
  static func privateDirectory(_ url: URL) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  /// Closes a copy to every other account.
  static func seal(_ file: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// A folder of its own for one received file or placeholder, named so two
  /// never meet.
  static func scratch(in root: URL) throws -> URL {
    try privateDirectory(root.appendingPathComponent(UUID().uuidString, isDirectory: true))
  }

  private static let sweptOnce = Once()

  /// What launch clears, once per run and off the main actor: old previews,
  /// leftovers, and the shared `/tmp` folders earlier versions used — which
  /// any account on the Mac could read.
  static func sweepOnce() {
    guard sweptOnce.claim() else { return }
    Task.detached(priority: .utility) { sweep() }
  }

  static func sweep(base: URL = disposable, now: Date = Date()) {
    trimPreviews(in: previews(in: base), limit: previewLimit, maxAge: previewAge, now: now)
    for root in [loading(in: base), staging(in: base)] {
      removeEntries(in: root, olderThan: now.addingTimeInterval(-leftoverAge))
    }
    #if os(macOS)
      if base == disposable {
        for legacy in ["Tether Files", "Tether Preview Loading"] {
          try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp").appendingPathComponent(legacy))
        }
      }
    #endif
  }

  /// Removes every host's previews not looked at within `maxAge`, then the
  /// least recently looked at until what is left fits `limit`.
  static func trimPreviews(in root: URL, limit: Int64, maxAge: TimeInterval, now: Date = Date()) {
    let manager = FileManager.default
    let hosts = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    let copies = hosts.flatMap { host in
      ((try? manager.contentsOfDirectory(at: host, includingPropertiesForKeys: keys)) ?? []).map { folder in
        let date = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
        return (folder: folder, date: date, bytes: size(of: folder))
      }
    }
    let cutoff = now.addingTimeInterval(-maxAge)
    var total = copies.reduce(0) { $0 + $1.bytes }
    for copy in copies.sorted(by: { $0.date < $1.date }) where copy.date < cutoff || total > limit {
      try? manager.removeItem(at: copy.folder)
      total -= copy.bytes
    }
  }

  private static func removeEntries(in root: URL, olderThan cutoff: Date) {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    for entry in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? [] {
      let date = (try? entry.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
      if date < cutoff { try? manager.removeItem(at: entry) }
    }
  }

  static func size(of folder: URL) -> Int64 {
    let files =
      (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return files.reduce(0) { total, file in
      total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
  }
}

/// True the first time it is asked, from any thread.
private final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
