import CryptoKit
import Foundation
import Tether

/// Where copies of remote files live on this machine while they are looked at.
///
/// Keyed by the far side's path, size and modification time, so a file that
/// has not changed is not fetched again and one that has is. The time is the
/// one the caller just read — a listing from before the write still names the
/// old copy. Per host, because `/home/ada/plot.png` on two machines is two
/// files. Under the disposable root (`LocalCopies`): everything here can be
/// fetched again, and a download moves the copy out rather than fetching it
/// twice.
struct FileCache: Sendable {
  /// This host's previews.
  let root: URL
  /// Every host's, which one limit and one age apply to.
  let previews: URL

  /// `base` is the disposable root; a test hands in a folder of its own.
  init(host: UUID, base: URL? = nil) {
    previews = LocalCopies.previews(in: base ?? LocalCopies.disposable)
    root = previews.appendingPathComponent(host.uuidString, isDirectory: true)
  }

  /// Where `entry` is kept, whether or not it is there yet. The directory is
  /// made, closed to other accounts; the file is not.
  func location(for entry: FileEntry) -> URL {
    let folder = root.appendingPathComponent(key(for: entry), isDirectory: true)
    try? LocalCopies.privateDirectory(folder)
    return folder.appendingPathComponent(Names.local(entry.name))
  }

  /// Moves the cached copy of `entry` to `destination` and forgets it.
  ///
  /// False when there is no copy, or the move did not land — the caller
  /// fetches instead. A move across volumes still copies on disk; it does
  /// not fetch the file again.
  func move(_ entry: FileEntry, to destination: URL) -> Bool {
    guard let url = cached(entry) else { return false }
    do {
      try FileManager.default.moveItem(at: url, to: destination)
    } catch {
      return false
    }
    let folder = url.deletingLastPathComponent()
    let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    if left.isEmpty { try? FileManager.default.removeItem(at: folder) }
    return true
  }

  /// The copy of `entry`, if one is already here and still the same file.
  func cached(_ entry: FileEntry) -> URL? {
    let url = root.appendingPathComponent(key(for: entry), isDirectory: true)
      .appendingPathComponent(Names.local(entry.name))
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    // Touched, so trimming keeps what was looked at most recently.
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: url.deletingLastPathComponent().path)
    return url
  }

  /// A copy that has just arrived: closed to other accounts, and the cache
  /// trimmed around it.
  @discardableResult
  func keep(_ copy: URL) -> URL {
    LocalCopies.seal(copy)
    trim(to: LocalCopies.previewLimit)
    return copy
  }

  /// Removes previews nobody has looked at for a day, then the least
  /// recently looked at — any host's — until what is left fits `limit`.
  func trim(to limit: Int64, maxAge: TimeInterval = LocalCopies.previewAge, now: Date = Date()) {
    LocalCopies.trimPreviews(in: previews, limit: limit, maxAge: maxAge, now: now)
  }

  private func key(for entry: FileEntry) -> String {
    let digest = SHA256.hash(data: Data(entry.path.utf8))
    let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    return "\(hex)-\(entry.size)-\(entry.modified ?? 0)"
  }
}
