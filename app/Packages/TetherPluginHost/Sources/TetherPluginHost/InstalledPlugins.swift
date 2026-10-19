import Foundation
import Observation
import TetherPluginKit

/// Owns installed bytes. Discovery only reads manifests; registration decides activation.
@MainActor @Observable
public final class InstalledPlugins {
  public let directory: URL
  public private(set) var problems: [String] = []
  public private(set) var pluginIDs: Set<String> = []
  private let registry: TetherPluginKit.PluginRegistry
  private let host: PluginHost
  private var installingIDs: Set<String> = []

  public init(directory: URL, registry: TetherPluginKit.PluginRegistry,
              host: PluginHost = PluginHost(consent: DialogConsent())) {
    self.directory = directory
    self.registry = registry
    self.host = host
    host.onStatus = { [weak registry] id, payload in
      (registry?.plugins.first { $0.metadata.id == id } as? WebPlugin)?.receiveStatus(payload)
    }
    host.onTabIndicators = { [weak registry] session, id, items in
      (registry?.plugins.first { $0.metadata.id == id } as? WebPlugin)?
        .receiveTabIndicators(items, session: session)
    }
  }

  public static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Tether/Plugins", directoryHint: .isDirectory)
  }

  public func discover() {
    problems = []
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let roots = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      // Existing installations already requested network consent in the former runtime flow.
      // Migrate their declared scope once so upgrading does not re-prompt on launch.
      if !FileManager.default.fileExists(atPath: networkGrantsURL.path) {
        var grants: [String: [String]] = [:]
        for root in roots {
          if let manifest = try? PackageValidator.validate(directory: root), manifest.permissions.contains(.network) {
            grants[manifest.id] = manifest.networkURLs.map(\.absoluteString).sorted()
          }
        }
        try writeNetworkGrants(grants)
      }
      for root in roots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        do {
          let manifest = try PackageValidator.validate(directory: root)
          if pluginIDs.contains(manifest.id) { continue }
          try register(root)
        } catch { problems.append("\(root.lastPathComponent): \(error.localizedDescription)") }
      }
    } catch { problems.append(error.localizedDescription) }
  }

  @discardableResult
  public func install(directory source: URL) async throws -> PluginRecord {
    let manifest = try PackageValidator.validate(directory: source)
    guard !registry.plugins.contains(where: { $0.metadata.id == manifest.id }) else {
      throw PluginHostError.duplicate(manifest.id)
    }
    guard installingIDs.insert(manifest.id).inserted else { throw PluginHostError.duplicate(manifest.id) }
    defer { installingIDs.remove(manifest.id) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stage = directory.appending(path: ".install-\(UUID().uuidString)", directoryHint: .isDirectory)
    let destination = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: stage) }
    try FileManager.default.copyItem(at: source, to: stage)
    _ = try PackageValidator.validate(directory: stage)
    try FileManager.default.moveItem(at: stage, to: destination)
    do {
      if manifest.permissions.contains(.network) {
        guard await host.authorizeNetwork(manifest) else { throw PluginHostError.consentDenied }
        try Task.checkCancellation()
        guard !registry.plugins.contains(where: { $0.metadata.id == manifest.id }) else { throw PluginHostError.duplicate(manifest.id) }
        var grants = readNetworkGrants()
        grants[manifest.id] = manifest.networkURLs.map(\.absoluteString).sorted()
        try writeNetworkGrants(grants)
      }
      return try register(destination)
    }
    catch { try? FileManager.default.removeItem(at: destination); throw error }
  }

  /// Installs the latest release of a GitHub repository. The address is the
  /// repository, `github.com/owner/name`, with no branch or tag.
  @discardableResult
  public func install(repository address: String) async throws -> PluginRecord {
    try await install(repository: address, fetch: GitHubLatestRelease())
  }

  @discardableResult
  func install(repository address: String, fetch: any ReleaseArchiveFetching) async throws -> PluginRecord {
    guard let repository = GitHubRepository.parse(address) else { throw PluginHostError.notARepository }
    let archive = try await fetch.latestArchive(owner: repository.owner, repository: repository.name)
    let staged = FileManager.default.temporaryDirectory.appending(
      path: "TetherPlugin-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staged) }
    try ZipArchive.extract(archive, to: staged)
    return try await install(directory: try packageRoot(in: staged))
  }

  private func packageRoot(in directory: URL) throws -> URL {
    if FileManager.default.fileExists(atPath: directory.appending(path: "manifest.json").path) { return directory }
    let children = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    let rooted = children.filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        && FileManager.default.fileExists(atPath: url.appending(path: "manifest.json").path)
    }
    guard rooted.count == 1, let root = rooted.first else {
      throw PluginHostError.package(.manifestMissing(directory.path))
    }
    return root
  }

  private func register(_ root: URL) throws -> PluginRecord {
    let manifest = try PackageValidator.validate(directory: root)
    guard !registry.plugins.contains(where: { $0.metadata.id == manifest.id }) else {
      throw PluginHostError.duplicate(manifest.id)
    }
    let approved = Set(readNetworkGrants()[manifest.id] ?? [])
    host.grantNetwork(pluginID: manifest.id, urls: manifest.networkURLs.filter { approved.contains($0.absoluteString) })
    let record = try host.install(directory: root)
    if !registry.isEnabled(record.id) { try host.setEnabled(false, id: record.id) }
    pluginIDs.insert(record.id)
    registry.register(WebPlugin(record: record, host: host))
    return record
  }

  private var networkGrantsURL: URL { directory.appending(path: ".network-grants.json") }

  private func readNetworkGrants() -> [String: [String]] {
    guard let data = try? Data(contentsOf: networkGrantsURL) else { return [:] }
    return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
  }

  private func writeNetworkGrants(_ grants: [String: [String]]) throws {
    try JSONEncoder().encode(grants).write(to: networkGrantsURL, options: .atomic)
  }

  public func uninstall(id: String) throws {
    guard pluginIDs.contains(id), let record = host.record(id) else { throw PluginHostError.unknownPlugin(id) }
    // Moving first is reversible if the filesystem refuses it. The running
    // page is then closed before any of its assets are removed.
    let removed = directory.appending(path: ".removed-\(UUID().uuidString)")
    try FileManager.default.moveItem(at: record.source.root, to: removed)
    registry.unregister(id: id)
    try host.uninstall(id: id)
    pluginIDs.remove(id)
    var grants = readNetworkGrants(); grants.removeValue(forKey: id)
    try writeNetworkGrants(grants)
    try FileManager.default.removeItem(at: removed)
  }
}
