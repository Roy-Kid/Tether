import Foundation
import TetherPluginKit

/// Installs web packages, and runs a page only after activation.
@MainActor
public final class PluginHost: PluginBridge {
  private let registry = PluginRegistry()
  private let gateway: CapabilityGateway
  public let api: PluginAPI
  private var runtimes: [UUID: any PluginRuntime] = [:]

  public var onStatus: (@MainActor (String, JSONValue) -> Void)?
  public var onTabIndicators: (@MainActor (UUID, String, [PluginTabIndicator]) -> Void)?

  public init(api: PluginAPI, streaming: any PluginStreaming = HTTPEventStream()) {
    self.api = api
    gateway = CapabilityGateway(consent: api.consent, api: api, streaming: streaming)
    api.gateway = gateway
    gateway.emit = { [weak self] session, event in
      guard let runtime = self?.runtimes[session] else { return }
      await runtime.receive(event: event, session: session)
    }
    gateway.status = { [weak self] session, payload in
      guard let self, let id = self.gateway.pluginID(for: session) else { return }
      self.onStatus?(id, payload)
    }
    gateway.tabIndicators = { [weak self] session, pluginID, items in
      self?.onTabIndicators?(session, pluginID, items)
    }
  }

  public var records: [PluginRecord] { registry.records }
  public var index: ContributionIndex { registry.index }
  public var liveSessions: Set<UUID> { Set(runtimes.keys) }

  public func record(_ id: String) -> PluginRecord? { registry.record(id) }

  @discardableResult
  public func install(directory: URL) throws -> PluginRecord {
    try registry.install(directory: directory)
  }

  public convenience init(
    consent: any ConsentAsking, presenting: (any PluginPresenting)? = nil,
    streaming: any PluginStreaming = HTTPEventStream()
  ) {
    self.init(api: PluginAPI(consent: consent, presenting: presenting), streaming: streaming)
  }

  public func authorizeNetwork(_ manifest: PluginManifest) async -> Bool {
    await gateway.authorizeNetwork(manifest)
  }

  public func grantNetwork(pluginID: String, urls: [URL]) {
    gateway.grantNetwork(pluginID: pluginID, urls: urls)
  }

  public func uninstall(id: String) throws {
    for session in gateway.sessions(for: id) {
      unload(session: session)
    }
    gateway.wipeStorage(pluginID: id)
    gateway.revokeNetworkConsent(pluginID: id)
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
  public func activate(
    id: String, runtime: any PluginRuntime, environment: PluginEnvironment = .none,
    reconnect: (@MainActor () async throws -> Void)? = nil
  ) async throws -> UUID {
    guard let record = registry.record(id) else { throw PluginHostError.unknownPlugin(id) }
    guard record.enabled else { throw PluginHostError.disabled(id) }
    // Installed bytes may have changed since discovery. Validate again before execution.
    let validated = try PackageValidator.validate(directory: record.source.root)
    guard validated == record.manifest else { throw PluginHostError.package(.malformed) }
    let session = UUID()
    guard let entry = PackagePaths.resolve(record.manifest.entrypoint, in: record.source.root) else {
      throw PluginHostError.package(.entrypointMissing)
    }
    runtime.bind(environment)
    gateway.open(session, record: record, environment: environment, reconnect: reconnect)
    runtimes[session] = runtime
    do {
      try await withTaskCancellationHandler {
        try await runtime.activate(session: session, root: record.source.root, entrypoint: entry, bridge: self)
        try Task.checkCancellation()
      } onCancel: {
        Task { @MainActor [weak self] in self?.unload(session: session) }
      }
    } catch {
      if runtimes.removeValue(forKey: session) != nil { runtime.unload(session: session) }
      gateway.close(session)
      throw error
    }
    guard runtimes[session] != nil, registry.record(id)?.enabled == true else {
      unload(session: session)
      throw PluginHostError.disabled(id)
    }
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
    guard message.utf8.count <= EventStreamDecoder.limit,
      let request = try? RPCCodec.decode(RPCRequest.self, from: message) else {
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
