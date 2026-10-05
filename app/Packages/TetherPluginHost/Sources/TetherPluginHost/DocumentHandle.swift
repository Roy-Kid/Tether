import Foundation

/// One document a session was allowed to read. The handle is an id. It has no path.
public struct DocumentHandle: Hashable, Sendable {
  public let id: UUID

  init(id: UUID = UUID()) {
    self.id = id
  }
}
