import Foundation

/// Installs web packages, and runs a page only after activation.
@MainActor
public final class PluginHost: PluginBridge {
  private let registry = PluginRegistry()
  private let gateway: CapabilityGateway
  private var runtimes: [UUID: any PluginRuntime] = [:]

  public init(consent: any ConsentAsking, notifying: any HostNotifying) {
    gateway = CapabilityGateway(consent: consent, notifying: notifying)
  }

  public var records: [PluginRecord] { registry.records }
  public var index: ContributionIndex { registry.index }
  public var liveSessions: Set<UUID> { Set(runtimes.keys) }

  public func record(_ id: String) -> PluginRecord? { registry.record(id) }

  @discardableResult
  public func install(directory: URL) throws -> PluginRecord {
    try registry.install(directory: directory)
  }

  public func uninstall(id: String) throws {
    for session in gateway.sessions(for: id) {
      unload(session: session)
    }
    gateway.wipeStorage(pluginID: id)
    try registry.uninstall(id: id)
  }

  public func setEnabled(_ enabled: Bool, id: String) throws {
    guard registry.record(id) != nil else { throw PluginHostError.unknownPlugin(id) }
    if !enabled {
      for session in gateway.sessions(for: id) {
        unload(session: session)
      }
    }
    try registry.setEnabled(enabled, id: id)
  }

  @discardableResult
  public func activate(id: String, runtime: any PluginRuntime) async throws -> UUID {
    guard let record = registry.record(id) else { throw PluginHostError.unknownPlugin(id) }
    guard record.enabled else { throw PluginHostError.disabled(id) }
    let session = UUID()
    gateway.open(session, record: record)
    guard let entry = PackagePaths.resolve(record.manifest.entrypoint, in: record.source.root) else {
      throw PluginHostError.package(.entrypointMissing)
    }
    do {
      try await runtime.activate(session: session, root: record.source.root, entrypoint: entry, bridge: self)
    } catch {
      gateway.close(session)
      throw error
    }
    runtimes[session] = runtime
    registry.setStatus(.activated, id: id)
    return session
  }

  public func unload(session: UUID) {
    guard let runtime = runtimes.removeValue(forKey: session) else { return }
    let owner = gateway.pluginID(for: session)
    runtime.unload(session: session)
    gateway.close(session)
    if let owner, gateway.sessions(for: owner).isEmpty {
      registry.setStatus(.unloaded, id: owner)
    }
  }

  public func grant(session: UUID, bytes: Data) async throws -> DocumentHandle {
    try await gateway.grant(session: session, bytes: bytes)
  }

  public func perform(_ request: RPCRequest) async -> RPCResponse {
    await gateway.response(to: request)
  }

  public func deliver(_ message: String) async -> String {
    guard let request = try? RPCCodec.decode(RPCRequest.self, from: message) else {
      return Self.malformed
    }
    let response = await gateway.response(to: request)
    return (try? RPCCodec.encode(response)) ?? Self.malformed
  }

  public func deliver(_ message: String, from session: UUID) async -> String {
    await deliver(RPCCodec.pin(message, to: session))
  }

  private static let malformed =
    #"{"api":1,"session":"00000000-0000-0000-0000-000000000000","id":"","ok":false,"payload":null,"error":"malformed"}"#
}
