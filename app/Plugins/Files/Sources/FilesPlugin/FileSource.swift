import Foundation
import Tether

/// What the browser asks of the far side. `RemoteFiles` is the one that
/// matters; the protocol exists so a test can answer instead of a server.
protocol FileSource: AnyObject, Sendable {
  /// Whether the far side is this machine, so its paths are paths here.
  var isLocal: Bool { get }
  func home() async throws -> String
  func list(_ directory: String) async throws -> [FileEntry]
  func stat(_ path: String) async throws -> FileEntry
  func lstat(_ path: String) async throws -> FileEntry
  func download(
    _ path: String, to destination: String, progress: (@Sendable (UInt64) -> Void)?
  ) async throws -> UInt64
  func upload(
    _ source: String, to path: String, replacing: Bool, progress: (@Sendable (UInt64) -> Void)?
  ) async throws -> UInt64
  func makeDirectory(_ path: String) async throws
  func rename(_ from: String, to: String, replacing: Bool) async throws
  func remove(_ path: String) async throws
  func removeTree(_ path: String) async throws -> UInt64
  func close() async
}

extension RemoteFiles: FileSource {}

/// A failure, as the one line the browser shows.
func describe(_ error: Error) -> String {
  (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
