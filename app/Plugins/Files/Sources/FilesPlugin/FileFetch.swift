import Foundation
import Tether

/// One remote file's bytes, fetched for a drag or a share without the main
/// actor.
///
/// A drag out of the list is a file promise, written on its own queue, and a
/// share asks from wherever the share sheet is. Neither may need the main
/// actor: a fetch that did — `FilesTab` is one — once waited for a main
/// thread that was waiting for it, and the app hung until it was force
/// quit. Everything here is the file session, the cache and the entry, all
/// of which can be used from any thread.
struct FileFetch: Sendable {
  let entry: FileEntry
  let session: Task<any FileSource, Error>?
  let cache: FileCache
  /// Where a promised file shows while it is written. A share has its own
  /// sheet and reports nowhere.
  var transfers: Transfers?

  /// A copy of the file on this machine: the file itself when the session is
  /// local, the cached copy when it is still the same file, or fetched now.
  func local() async throws -> URL {
    let source = try await open()
    if source.isLocal { return URL(fileURLWithPath: entry.path) }
    return try await cachedCopy(from: source, progress: nil)
  }

  /// Writes the file at `destination`, which must not exist: what a file
  /// promise is asked to do once something has accepted the drop.
  ///
  /// Refused before anything is fetched when the name is taken or the folder
  /// cannot be written. Whoever asked owns the conflict; nothing is
  /// replaced. The copy lands whole — a fetch goes to the cache first — and
  /// the cached copy stays for the next look.
  func write(to destination: URL, progress: (@Sendable (UInt64) -> Void)?) async throws {
    try Self.refuseUnwritable(destination)
    let source = try await open()
    let copy: URL
    if source.isLocal {
      copy = URL(fileURLWithPath: entry.path)
    } else {
      copy = try await cachedCopy(from: source, progress: progress)
    }
    try Task.checkCancellation()
    try FileManager.default.copyItem(at: copy, to: destination)

  }

  /// The session this fetch was made with. None means the tab has no files
  /// to give: that fails now, rather than waiting for a reconnect.
  private func open() async throws -> any FileSource {
    guard let session else { throw FileError.disconnected(cause: "No file session.") }
    return try await session.value
  }

  /// The cached copy when it is still the same file, or fetched into the
  /// cache now. The far side is asked first, so a listing from before a write
  /// does not name a stale copy.
  private func cachedCopy(
    from source: any FileSource, progress: (@Sendable (UInt64) -> Void)?
  ) async throws -> URL {
    var current = entry
    if let found = try? await source.stat(entry.path), found.kind == .file { current = found }
    if let cached = cache.cached(current) { return cached }
    let destination = cache.location(for: current)
    _ = try await source.download(current.path, to: destination.path, progress: progress)
    return cache.keep(destination)
  }

  private static func refuseUnwritable(_ destination: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: destination.path) {
      throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
    }
    let folder = destination.deletingLastPathComponent().path
    if !manager.isWritableFile(atPath: folder) {
      throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path])
    }
  }
}
