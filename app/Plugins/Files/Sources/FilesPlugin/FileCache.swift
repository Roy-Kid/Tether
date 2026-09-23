import CryptoKit
import Foundation
import Tether

/// Where copies of remote files live on this machine while they are looked at.
///
/// Keyed by the far side's path, size and modification time, so a file that
/// has not changed is not fetched again and one that has is. Per host,
/// because `/home/ada/plot.png` on two machines is two files. In the caches
/// directory, which the system may empty: everything here can be fetched
/// again.
struct FileCache: Sendable {
  let root: URL

  init(host: UUID, base: URL? = nil) {
    let caches =
      base ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    root = caches.appendingPathComponent("Tether Files", isDirectory: true)
      .appendingPathComponent(host.uuidString, isDirectory: true)
  }

  /// Where `entry` is kept, whether or not it is there yet. The directory is
  /// made; the file is not.
  func location(for entry: FileEntry) -> URL {
    let folder = root.appendingPathComponent(key(for: entry), isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(Names.local(entry.name))
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

  /// Removes the least recently used copies until what is left fits `limit`.
  func trim(to limit: Int64) {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    guard
      let folders = try? manager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: keys)
    else { return }
    let sized = folders.map { folder -> (URL, Date, Int64) in
      let date =
        (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      return (folder, date, size(of: folder))
    }
    var total = sized.reduce(0) { $0 + $1.2 }
    for (folder, _, bytes) in sized.sorted(by: { $0.1 < $1.1 }) where total > limit {
      try? manager.removeItem(at: folder)
      total -= bytes
    }
  }

  private func key(for entry: FileEntry) -> String {
    let digest = SHA256.hash(data: Data(entry.path.utf8))
    let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    return "\(hex)-\(entry.size)-\(entry.modified ?? 0)"
  }

  private func size(of folder: URL) -> Int64 {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return files.reduce(0) { total, file in
      total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
  }
}
