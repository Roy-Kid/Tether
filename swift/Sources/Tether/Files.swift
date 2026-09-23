import Foundation
import TetherFFIBindings

public typealias FileEntry = TetherFFIBindings.FileEntry
public typealias FileKind = TetherFFIBindings.FileKind

/// Why a file operation did not happen, in shapes a person can act on.
///
/// The server's own status code is context inside `cause`, never a case
/// (spec §18).
public enum FileError: Error, Equatable, Sendable, LocalizedError {
  case notFound(path: String)
  case exists(path: String)
  case permissionDenied(path: String)
  case notEmpty(path: String)
  case cancelled
  case disconnected(cause: String)
  case failed(cause: String)

  public var errorDescription: String? {
    switch self {
    case .notFound(let path): "“\(Self.name(path))” does not exist."
    case .exists(let path): "“\(Self.name(path))” already exists."
    case .permissionDenied(let path): "Not allowed to change “\(Self.name(path))”."
    case .notEmpty(let path): "“\(Self.name(path))” is not empty."
    case .cancelled: "Cancelled."
    case .disconnected(let cause): "The connection was lost. \(cause)"
    case .failed(let cause): cause
    }
  }

  /// The last component, for a sentence. The full path is still in the case.
  private static func name(_ path: String) -> String {
    let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
  }

  static func translate(_ error: TetherFFIBindings.FileError) -> FileError {
    switch error {
    case .NotFound(let path): .notFound(path: path)
    case .Exists(let path): .exists(path: path)
    case .PermissionDenied(let path): .permissionDenied(path: path)
    case .NotEmpty(let path): .notEmpty(path: path)
    case .Cancelled: .cancelled
    case .Disconnected(let cause): .disconnected(cause: cause)
    case .Failed(let cause): .failed(cause: cause)
    }
  }
}

extension RemoteConnection {
  /// Starts a file session where this lease's shell is running.
  ///
  /// SFTP beside the shell, not through it: a listing never waits behind the
  /// terminal, and closing the files closes nothing else. On this machine it
  /// is the same protocol, spoken to the `sftp-server` OpenSSH installed.
  public func files() async throws -> RemoteFiles {
    let files = try await Tether.cancellable { try await self.inner.files(cancellation: $0) }
    return RemoteFiles(files)
  }
}

/// Files on the machine a session's shell is running on.
///
/// Paths are the far side's POSIX paths, as strings. Local paths — where a
/// download lands, what an upload reads — must be absolute.
public final class RemoteFiles: Sendable {
  private let inner: TetherFFIBindings.RemoteFiles
  init(_ inner: TetherFFIBindings.RemoteFiles) { self.inner = inner }

  /// Whether these files are on this machine, so a remote path is also a
  /// local one and can be shown in place rather than copied.
  public var isLocal: Bool { inner.isLocal() }

  /// The account's home directory, as an absolute path.
  public func home() async throws -> String {
    try await filed { try await self.inner.home() }
  }

  /// `path` with `.`, `..` and links resolved.
  public func resolve(_ path: String) async throws -> String {
    try await filed { try await self.inner.resolve(path: path) }
  }

  /// What is in `directory`, sorted by name, links listed as links.
  public func list(_ directory: String) async throws -> [FileEntry] {
    try await cancellableFiled { try await self.inner.list(directory: directory, cancellation: $0) }
  }

  /// What `path` is, looking through a link.
  public func stat(_ path: String) async throws -> FileEntry {
    try await filed { try await self.inner.stat(path: path) }
  }

  /// What `path` is, reporting a link as a link.
  public func lstat(_ path: String) async throws -> FileEntry {
    try await filed { try await self.inner.lstat(path: path) }
  }

  /// Copies `path` to `destination` on this machine. `destination` appears
  /// only once the copy is whole; cancelling the task leaves nothing behind.
  @discardableResult
  public func download(
    _ path: String, to destination: String,
    progress: (@Sendable (UInt64) -> Void)? = nil
  ) async throws -> UInt64 {
    let reporter = progress.map(Reporter.init)
    return try await cancellableFiled {
      try await self.inner.download(
        path: path, destination: destination, progress: reporter, cancellation: $0)
    }
  }

  /// Copies `source` on this machine to `path`. Refuses to replace an
  /// existing file unless `replacing` is set, and never replaces a directory.
  @discardableResult
  public func upload(
    _ source: String, to path: String, replacing: Bool = false,
    progress: (@Sendable (UInt64) -> Void)? = nil
  ) async throws -> UInt64 {
    let reporter = progress.map(Reporter.init)
    return try await cancellableFiled {
      try await self.inner.upload(
        source: source, path: path, replace: replacing, progress: reporter, cancellation: $0)
    }
  }

  public func makeDirectory(_ path: String) async throws {
    try await filed { try await self.inner.makeDirectory(path: path) }
  }

  /// Moves `from` to `to`, replacing a file at `to` only when asked.
  public func rename(_ from: String, to: String, replacing: Bool = false) async throws {
    try await filed { try await self.inner.rename(from: from, to: to, replace: replacing) }
  }

  /// Removes a file, a link, or an empty directory.
  public func remove(_ path: String) async throws {
    try await filed { try await self.inner.remove(path: path) }
  }

  /// Removes `path` and everything under it without following links, and
  /// returns how many things were removed.
  @discardableResult
  public func removeTree(_ path: String) async throws -> UInt64 {
    try await cancellableFiled { try await self.inner.removeTree(path: path, cancellation: $0) }
  }

  /// Ends the file session. The shell is untouched.
  public func close() async { await inner.close() }
}

/// Carries a Swift closure across as the progress callback.
private final class Reporter: TetherFFIBindings.TransferProgress, Sendable {
  private let report: @Sendable (UInt64) -> Void
  init(_ report: @escaping @Sendable (UInt64) -> Void) { self.report = report }
  func advanced(bytes: UInt64) { report(bytes) }
}

private func filed<T>(_ body: () async throws -> T) async throws -> T {
  do {
    return try await body()
  } catch let error as TetherFFIBindings.FileError {
    throw FileError.translate(error)
  }
}

/// The token dance from `Tether.cancellable`, translating file errors.
private func cancellableFiled<T: Sendable>(
  _ body: @escaping @Sendable (TetherFFIBindings.CancellationToken) async throws -> T
) async throws -> T {
  let token = TetherFFIBindings.CancellationToken()
  return try await withTaskCancellationHandler {
    if Task.isCancelled { throw FileError.cancelled }
    return try await filed { try await body(token) }
  } onCancel: {
    token.cancel()
  }
}
