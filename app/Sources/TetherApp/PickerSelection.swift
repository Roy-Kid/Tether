import TetherUI

/// Keyboard highlight is separate from the active workspace. Filtering keeps
/// an available choice by identity; moving never lands on a disabled command.
struct PickerSelection<ID: Hashable> {
  private(set) var id: ID?

  init(id: ID? = nil) { self.id = id }

  mutating func reconcile(_ available: [ID]) {
    if let id, available.contains(id) { return }
    id = available.first
  }

  mutating func move(forward: Bool, in available: [ID]) {
    navigate(forward ? .next : .previous, in: available)
  }

  mutating func navigate(_ movement: PickerMovement, pageSize: Int = 8, in available: [ID]) {
    guard !available.isEmpty else { id = nil; return }
    if movement == .first { id = available.first; return }
    if movement == .last { id = available.last; return }
    let offset = movement.offset(pageSize: pageSize)
    guard let id, let index = available.firstIndex(of: id) else {
      self.id = offset > 0 ? available.first : available.last
      return
    }
    self.id = available[min(available.count - 1, max(0, index + offset))]
  }
}
