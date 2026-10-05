import Foundation

public struct ContributionMatch: Sendable, Equatable, Identifiable {
  public let pluginID: String
  public let contributionID: String
  public let kind: ContributionKind
  public let suffixes: [String]

  public var id: String { "\(pluginID) \(contributionID)" }
}

/// Built from manifests. Looking up a suffix does not start a plugin.
public struct ContributionIndex: Sendable, Equatable {
  public private(set) var viewers: [ContributionMatch] = []
  public private(set) var commands: [ContributionMatch] = []
  public private(set) var panels: [ContributionMatch] = []

  public func matches(suffix: String) -> [ContributionMatch] {
    let key = Self.normalize(suffix)
    guard !key.isEmpty else { return [] }
    return viewers.filter { $0.suffixes.contains(key) }
  }

  mutating func add(_ record: PluginRecord) {
    for contribution in record.manifest.contributions {
      let match = ContributionMatch(
        pluginID: record.id, contributionID: contribution.id, kind: contribution.kind,
        suffixes: contribution.suffixes)
      switch contribution.kind {
      case .viewer: viewers.append(match)
      case .command: commands.append(match)
      case .panel: panels.append(match)
      }
    }
  }

  static func normalize(_ suffix: String) -> String {
    suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }
}
