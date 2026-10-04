import Foundation
import TetherFFIBindings

/// Local terminal content, independent of the live scrollback memory limit.
/// The embedding app chooses its directory, retention and deletion policy.
public final class SessionHistory: Sendable {
  let inner: TetherFFIBindings.SessionHistory

  /// `nil` retains all rows. Reopening continues an existing archive.
  public init(directory: URL, lineLimit: UInt64?, restoring: Bool = false) throws {
    inner = try Tether.mappedSync {
      try TetherFFIBindings.SessionHistory.open(directory: directory.path, lineLimit: lineLimit, restoring: restoring)
    }
  }

  public var error: String? { inner.error() }
}
