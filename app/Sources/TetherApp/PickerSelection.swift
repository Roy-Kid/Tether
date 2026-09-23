/// Keyboard highlight is separate from the active workspace. Filtering keeps
/// an available choice by identity; moving never lands on a disabled command.
struct PickerSelection<ID: Hashable> {
  private(set) var id: ID?

  mutating func reconcile(_ available: [ID]) {
    if let id, available.contains(id) { return }
    id = available.first
  }

  mutating func move(forward: Bool, in available: [ID]) {
    guard !available.isEmpty else { id = nil; return }
    guard let id, let index = available.firstIndex(of: id) else {
      self.id = forward ? available.first : available.last
      return
    }
    self.id = available[min(available.count - 1, max(0, index + (forward ? 1 : -1)))]
  }
}
