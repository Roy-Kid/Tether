import Foundation

/// App-owned panes. Each leaf displays one existing workspace; the session and
/// its connection remain owned by TabSet, never by the layout.
enum SplitDirection: String, CaseIterable, Codable {
  case right, down
}

indirect enum WorkspaceSplit: Equatable, Codable {
  case tab(UUID)
  case split(SplitDirection, WorkspaceSplit, WorkspaceSplit)

  var ids: [UUID] {
    switch self {
    case .tab(let id): [id]
    case .split(_, let first, let second): first.ids + second.ids
    }
  }

  func replacing(_ id: UUID, with replacement: WorkspaceSplit) -> WorkspaceSplit {
    switch self {
    case .tab(let current): current == id ? replacement : self
    case .split(let direction, let first, let second):
      .split(direction, first.replacing(id, with: replacement), second.replacing(id, with: replacement))
    }
  }

  func removing(_ id: UUID) -> WorkspaceSplit? {
    switch self {
    case .tab(let current): return current == id ? nil : self
    case .split(let direction, let first, let second):
      let a = first.removing(id), b = second.removing(id)
      if let a, let b { return .split(direction, a, b) }
      return a ?? b
    }
  }
}

extension WorkspaceSplit {
  /// Ignore stale leaves rather than letting corrupt history display foreign sessions.
  func remapping(_ ids: [UUID: UUID]) -> WorkspaceSplit? {
    switch self {
    case .tab(let id): return ids[id].map { .tab($0) }
    case .split(let direction, let first, let second):
      let a = first.remapping(ids), b = second.remapping(ids)
      if let a, let b { return .split(direction, a, b) }
      return a ?? b
    }
  }
}
