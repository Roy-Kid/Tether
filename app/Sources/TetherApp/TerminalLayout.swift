import Foundation
import Observation

/// A workspace tree contains IDs, never transports or UI framework objects.
indirect enum TerminalLayout: Codable, Equatable {
  case pane(UUID)
  case split(vertical: Bool, ratio: Double, first: TerminalLayout, second: TerminalLayout)

  var leaves: [UUID] {
    switch self {
    case .pane(let id): [id]
    case .split(_, _, let a, let b): a.leaves + b.leaves
    }
  }

  var minimumSize: CGSize {
    switch self {
    case .pane: return CGSize(width: 160, height: 100)
    case .split(let vertical, _, let a, let b):
      return vertical ? CGSize(width: max(a.minimumSize.width, b.minimumSize.width), height: a.minimumSize.height + 1 + b.minimumSize.height)
        : CGSize(width: a.minimumSize.width + 1 + b.minimumSize.width, height: max(a.minimumSize.height, b.minimumSize.height))
    }
  }

  func isValid(panes: Set<UUID>) -> Bool {
    func valid(_ node: Self) -> Bool {
      switch node {
      case .pane: return true
      case .split(_, let ratio, let a, let b): return ratio.isFinite && ratio > 0 && ratio < 1 && valid(a) && valid(b)
      }
    }
    return valid(self) && Set(leaves) == panes && leaves.count == panes.count
  }

  func splitting(_ id: UUID, adding: UUID, vertical: Bool) -> Self {
    switch self {
    case .pane(let existing):
      existing == id ? .split(vertical: vertical, ratio: 0.5, first: self, second: .pane(adding)) : self
    case .split(let axis, let ratio, let a, let b):
      .split(vertical: axis, ratio: ratio, first: a.splitting(id, adding: adding, vertical: vertical),
        second: b.splitting(id, adding: adding, vertical: vertical))
    }
  }

  func removing(_ id: UUID) -> Self? {
    switch self {
    case .pane(let existing): return existing == id ? nil : self
    case .split(let axis, let ratio, let a, let b):
      let first = a.removing(id), second = b.removing(id)
      guard let first else { return second }
      guard let second else { return first }
      return .split(vertical: axis, ratio: ratio, first: first, second: second)
    }
  }

  func remapping(_ ids: [UUID: UUID]) -> Self {
    switch self {
    case .pane(let id): return .pane(ids[id] ?? id)
    case .split(let axis, let ratio, let a, let b):
      return .split(vertical: axis, ratio: ratio, first: a.remapping(ids), second: b.remapping(ids))
    }
  }
  func sibling(of id: UUID) -> (node: Self, vertical: Bool, before: Bool, ratio: Double)? {
    guard case .split(let axis, let ratio, let a, let b) = self else { return nil }
    if a == .pane(id) { return (b, axis, true, ratio) }
    if b == .pane(id) { return (a, axis, false, ratio) }
    return a.sibling(of: id) ?? b.sibling(of: id)
  }
  func restoring(_ pane: UUID, beside neighbors: Set<UUID>, vertical: Bool, before: Bool, ratio: Double) -> Self {
    if case .split(let axis, let old, let a, let b) = self {
      if neighbors.isSubset(of: Set(a.leaves)) { return .split(vertical: axis, ratio: old,
        first: a.restoring(pane, beside: neighbors, vertical: vertical, before: before, ratio: ratio), second: b) }
      if neighbors.isSubset(of: Set(b.leaves)) { return .split(vertical: axis, ratio: old,
        first: a, second: b.restoring(pane, beside: neighbors, vertical: vertical, before: before, ratio: ratio)) }
    }
    let ratio = ratio.isFinite ? min(0.9999, max(0.0001, ratio)) : 0.5
    return .split(vertical: vertical, ratio: ratio, first: before ? .pane(pane) : self, second: before ? self : .pane(pane))
  }
  func neighbor(of id: UUID) -> (UUID, Bool)? {
    guard case .split(let axis, _, let a, let b) = self else { return nil }
    if a == .pane(id) { return (b.leaves[0], axis) }
    if b == .pane(id) { return (a.leaves[0], axis) }
    return a.neighbor(of: id) ?? b.neighbor(of: id)
  }

  func replacing(_ leaves: [UUID], ratio: Double) -> Self {
    guard case .split(let axis, let old, let a, let b) = self else { return self }
    if self.leaves == leaves {
      return .split(vertical: axis, ratio: min(0.9999, max(0.0001, ratio)), first: a, second: b)
    }
    return .split(vertical: axis, ratio: old, first: a.replacing(leaves, ratio: ratio), second: b.replacing(leaves, ratio: ratio))
  }
}

@MainActor @Observable
final class TerminalWorkspace {
  let id: UUID
  var layout: TerminalLayout
  var focused: UUID
  var maximized = false
  var paneFrames: [UUID: CGRect] = [:]
  let host: Host
  var name: String
  init(_ tab: SessionTab, host: Host? = nil, id: UUID? = nil) {
    self.id = id ?? UUID()
    layout = .pane(tab.id)
    focused = tab.id
    self.host = host ?? tab.host
    name = tab.name
  }
}
