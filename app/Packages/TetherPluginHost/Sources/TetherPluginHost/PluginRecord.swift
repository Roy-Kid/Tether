import Foundation

public enum PluginStatus: String, Sendable, Equatable {
  /// Manifest accepted. The page has not run.
  case installed
  /// Contributions have been read off the manifest.
  case discovered
  /// Contributions are in the index. Still no page.
  case registered
  /// A web view exists for at least one session.
  case activated
  /// The last session was released. The registry entry remains.
  case unloaded
}

/// Where the package bytes came from. The page never sees this.
public struct PluginSource: Sendable, Equatable {
  public let kind: String
  public let root: URL

  init(local root: URL) {
    kind = "local"
    self.root = root
  }
}

public struct PluginRecord: Sendable, Equatable, Identifiable {
  public let manifest: PluginManifest
  public let source: PluginSource
  public var status: PluginStatus
  public var enabled: Bool

  public var id: String { manifest.id }

  init(manifest: PluginManifest, source: PluginSource, status: PluginStatus, enabled: Bool) {
    self.manifest = manifest
    self.source = source
    self.status = status
    self.enabled = enabled
  }
}
