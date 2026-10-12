import Foundation
import Tether

#if os(macOS)
  import CoreGraphics
#endif

/// One remote file's bytes, fetched for a drag or a share without the main
/// actor.
///
/// A drop asks for a dragged file's URL on the main thread and waits there
/// until it has one. A fetch that needed the main actor — `FilesTab` is
/// one — waited for the thread that was waiting for it, and the app hung
/// until it was force quit. Everything here is the file session, the cache
/// and the entry, all of which can be used from any thread.
struct FileFetch: Sendable {
  enum Refusal: Error {
    /// The drop is on this app, where a file row means its path.
    case insideThisApp
  }

  let entry: FileEntry
  let session: Task<any FileSource, Error>?
  let cache: FileCache
  /// Whether a drop is landing on one of this app's own windows.
  var insideThisApp: @Sendable () -> Bool = DropSite.isThisApp

  /// The copy a drop takes. Inside this app there is none: the drop has the
  /// path, and fetching the file would stall the window for a download that
  /// nothing there wants.
  func forDrop() async throws -> URL {
    if insideThisApp() { throw Refusal.insideThisApp }
    return try await local()
  }

  /// A copy of the file on this machine: the file itself when the session is
  /// local, the cached copy when it is still the same file, or fetched now.
  func local() async throws -> URL {
    guard let session else { throw FileError.disconnected(cause: "No file session.") }
    let source = try await session.value
    if source.isLocal { return URL(fileURLWithPath: entry.path) }
    var current = entry
    if let found = try? await source.stat(entry.path), found.kind == .file { current = found }
    if let cached = cache.cached(current) { return cached }
    let destination = cache.location(for: current)
    _ = try await source.download(current.path, to: destination.path, progress: nil)
    cache.trim(to: FilesTab.cacheLimit)
    return destination
  }
}

/// Where a drop is landing, asked from whichever thread is resolving it.
enum DropSite {
  /// Whether the frontmost window under the pointer is this process's own.
  ///
  /// A drop happens where the pointer is, onto the window there. Windows at
  /// or above the dragging level — the dragged image — are not targets.
  /// Window server queries are thread-safe; AppKit's window list is not.
  static func isThisApp() -> Bool {
    #if os(macOS)
      guard let pointer = CGEvent(source: nil)?.location,
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
          as? [[String: Any]]
      else { return false }
      let dragging = Int(CGWindowLevelForKey(.draggingWindow))
      for window in windows {
        guard let layer = window[kCGWindowLayer as String] as? Int, layer < dragging,
          let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
          let bounds = window[kCGWindowBounds as String] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(pointer)
        else { continue }
        return (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } == getpid()
      }
      return false
    #else
      return false
    #endif
  }
}
