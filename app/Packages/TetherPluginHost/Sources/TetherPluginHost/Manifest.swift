import Foundation

/// The only runtime a store build will load.
public enum PluginRuntimeKind: String, Sendable, Equatable {
  case web
}

public enum ContributionKind: String, Codable, Sendable, Equatable {
  case viewer
  case command
  case panel
}

/// A permission the manifest may name. `network` is recognized and grants nothing.
public enum Permission: String, Codable, Sendable, Equatable, CaseIterable {
  case documentRead = "document.read"
  case storagePlugin = "storage.plugin"
  case network
}

public struct Contribution: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: ContributionKind
  /// Lowercased suffixes, without a leading dot. Empty for a command or a panel.
  public let suffixes: [String]

  init(id: String, kind: ContributionKind, suffixes: [String]) {
    self.id = id
    self.kind = kind
    self.suffixes = suffixes
  }
}

/// The static contract. Parsed at install. The page has not run.
public struct PluginManifest: Sendable, Equatable {
  public static let api = 1

  public let id: String
  public let name: String
  public let publisher: String
  public let version: String
  public let api: Int
  public let runtime: PluginRuntimeKind
  public let entrypoint: String
  public let ageRating: String
  public let link: URL
  public let permissions: [Permission]
  public let contributions: [Contribution]

  init(
    id: String, name: String, publisher: String, version: String, api: Int,
    runtime: PluginRuntimeKind, entrypoint: String, ageRating: String, link: URL,
    permissions: [Permission], contributions: [Contribution]
  ) {
    self.id = id
    self.name = name
    self.publisher = publisher
    self.version = version
    self.api = api
    self.runtime = runtime
    self.entrypoint = entrypoint
    self.ageRating = ageRating
    self.link = link
    self.permissions = permissions
    self.contributions = contributions
  }

  public func allows(_ permission: Permission) -> Bool {
    permissions.contains(permission)
  }
}

struct RawManifest: Decodable {
  struct RawContribution: Decodable {
    var kind: String
    var id: String
    var suffixes: [String]?
  }

  var id: String
  var name: String
  var publisher: String
  var version: String
  var api: Int
  var runtime: String
  var entrypoint: String
  var ageRating: String
  var link: String
  var permissions: [String]
  var contributions: [RawContribution]
}
