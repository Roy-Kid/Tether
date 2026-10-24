import Foundation

/// App-owned panes. Each leaf displays one existing workspace; the session and
/// its connection remain owned by TabSet, never by the layout.
enum SplitDirection: String, CaseIterable, Codable {
  case left, right, up, down

  /// Which side of a rectangle a drop landed on.
  /// A wide tab uses its left and right halves. A tall one uses top and bottom.
  /// A pane uses a band along each edge and ignores the middle.
  static func drop(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, band: CGFloat?) -> SplitDirection? {
    guard width > 0, height > 0 else { return nil }
    if let band {
      let left = x / width, right = 1 - left, top = y / height, bottom = 1 - top
      let edges: [(SplitDirection, CGFloat)] = [(.left, left), (.right, right), (.up, top), (.down, bottom)]
      guard let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 <= band else { return nil }
      return nearest.0
    }
    if height > width { return y < height / 2 ? .up : .down }
    return x < width / 2 ? .left : .right
  }
}

indirect enum WorkspaceSplit: Equatable, Codable {
  case tab(UUID)
  /// Children are in visual order: left to right or top to bottom.
  /// `fraction` is the first child's share of the split, so a host change
  /// draws the same panes instead of asking the system split view to remember.
  case split(SplitDirection, WorkspaceSplit, WorkspaceSplit, Double)

  var ids: [UUID] {
    switch self {
    case .tab(let id): [id]
    case .split(_, let first, let second, _): first.ids + second.ids
    }
  }

  func replacing(_ id: UUID, with replacement: WorkspaceSplit) -> WorkspaceSplit {
    switch self {
    case .tab(let current): current == id ? replacement : self
    case .split(let direction, let first, let second, let fraction):
      .split(direction, first.replacing(id, with: replacement), second.replacing(id, with: replacement), fraction)
    }
  }

  func removing(_ id: UUID) -> WorkspaceSplit? {
    switch self {
    case .tab(let current): return current == id ? nil : self
    case .split(let direction, let first, let second, let fraction):
      let a = first.removing(id), b = second.removing(id)
      if let a, let b { return .split(direction, a, b, fraction) }
      return a ?? b
    }
  }

  func withFraction(_ fraction: Double) -> WorkspaceSplit {
    guard case .split(let direction, let first, let second, _) = self else { return self }
    return .split(direction, first, second, fraction)
  }

  private enum CodingKeys: String, CodingKey { case tab, split }
  private enum ValueKeys: String, CodingKey { case _0, _1, _2, _3 }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.tab) {
      let values = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: .tab)
      self = .tab(try values.decode(UUID.self, forKey: ._0))
      return
    }
    let values = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: .split)
    let direction = try values.decode(SplitDirection.self, forKey: ._0)
    let first = try values.decode(WorkspaceSplit.self, forKey: ._1)
    let second = try values.decode(WorkspaceSplit.self, forKey: ._2)
    // Layouts saved before a fraction was kept open as an even split.
    let fraction = try values.decodeIfPresent(Double.self, forKey: ._3) ?? 0.5
    self = .split(direction, first, second, fraction)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .tab(let id):
      var values = container.nestedContainer(keyedBy: ValueKeys.self, forKey: .tab)
      try values.encode(id, forKey: ._0)
    case .split(let direction, let first, let second, let fraction):
      var values = container.nestedContainer(keyedBy: ValueKeys.self, forKey: .split)
      try values.encode(direction, forKey: ._0)
      try values.encode(first, forKey: ._1)
      try values.encode(second, forKey: ._2)
      try values.encode(fraction, forKey: ._3)
    }
  }
}

extension WorkspaceSplit {
  /// Ignore stale leaves rather than letting corrupt history display foreign sessions.
  func remapping(_ ids: [UUID: UUID]) -> WorkspaceSplit? {
    switch self {
    case .tab(let id): return ids[id].map { .tab($0) }
    case .split(let direction, let first, let second, let fraction):
      let a = first.remapping(ids), b = second.remapping(ids)
      if let a, let b { return .split(direction, a, b, fraction) }
      return a ?? b
    }
  }
}
