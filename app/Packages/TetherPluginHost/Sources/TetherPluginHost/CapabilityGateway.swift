import Foundation
import TetherPluginKit

public enum PluginHostError: Error, Equatable {
  case package(PackageFailure)
  case duplicate(String)
  case unknownPlugin(String)
  case disabled(String)
  case consentDenied
  case noSession
  case permissionDenied
  case notARepository
  case noRelease
  case remoteUnavailable
  case archiveUnreadable
  case archiveTooLarge
}

@MainActor
final class CapabilityGateway {
  private struct Session {
    let pluginID: String
    let pluginName: String
    let permissions: Set<Permission>
    let networkURLs: Set<URL>
    let reportsStatus: Bool
    let reportsTabIndicators: Bool
    var documents: [UUID: Data] = [:]
    var storageAsked = false
    var storageAllowed = false
    var environment: PluginEnvironment = .none
    var reconnect: (@MainActor () async throws -> Void)?
  }

  private let consent: any ConsentAsking
  private let api: PluginAPI
  private var sessions: [UUID: Session] = [:]
  private let streaming: any PluginStreaming
  private var streams: [UUID: (session: UUID, task: Task<Void, Never>)] = [:]
  var emit: (@MainActor (UUID, JSONValue) async -> Void)?
  var status: (@MainActor (UUID, JSONValue) -> Void)?
  var tabIndicators: (@MainActor (UUID, String, [PluginTabIndicator]) -> Void)?
  private var networkGrants: [String: Set<URL>] = [:]

  init(consent: any ConsentAsking, api: PluginAPI, streaming: any PluginStreaming) {
    self.consent = consent
    self.api = api
    self.streaming = streaming
  }

  func open(
    _ id: UUID, record: PluginRecord, environment: PluginEnvironment = .none,
    reconnect: (@MainActor () async throws -> Void)? = nil
  ) {
    sessions[id] = Session(
      pluginID: record.id, pluginName: record.manifest.name,
      permissions: Set(record.manifest.permissions), networkURLs: Set(record.manifest.networkURLs),
      reportsStatus: record.manifest.contributions.contains { $0.kind == .statusBar },
      reportsTabIndicators: record.manifest.contributions.contains { $0.kind == .tabIndicator },
      environment: environment, reconnect: reconnect)
  }

  func close(_ id: UUID) {
    if let session = sessions[id], session.reportsTabIndicators {
      tabIndicators?(id, session.pluginID, [])
    }
    sessions[id] = nil
    for stream in streams.keys.filter({ streams[$0]?.session == id }) {
      streams.removeValue(forKey: stream)?.task.cancel()
    }
  }

  func pluginID(for session: UUID) -> String? {
    sessions[session]?.pluginID
  }

  func sessions(for pluginID: String) -> [UUID] {
    sessions.compactMap { $0.value.pluginID == pluginID ? $0.key : nil }
  }

  func wipeStorage(pluginID: String) {
    api.wipe(pluginID: pluginID)
  }

  func revokeNetworkConsent(pluginID: String) { networkGrants.removeValue(forKey: pluginID) }

  func authorizeNetwork(_ manifest: PluginManifest) async -> Bool {
    guard manifest.permissions.contains(.network) else { return true }
    return await consent.ask(pluginName: manifest.name, permission: .network,
      resources: manifest.networkURLs.map(\.absoluteString).sorted())
  }

  func grantNetwork(pluginID: String, urls: [URL]) { networkGrants[pluginID] = Set(urls) }

  func grant(session id: UUID, bytes: Data) async throws -> DocumentHandle {
    guard let session = sessions[id] else { throw PluginHostError.noSession }
    guard session.permissions.contains(.documentRead) else { throw PluginHostError.permissionDenied }
    let allowed = await consent.ask(pluginName: session.pluginName, permission: .documentRead)
    guard var current = sessions[id] else { throw PluginHostError.noSession }
    guard allowed else { throw PluginHostError.consentDenied }
    let handle = DocumentHandle()
    current.documents[handle.id] = bytes
    sessions[id] = current
    return handle
  }

  func response(to request: RPCRequest) async -> RPCResponse {
    guard request.api == PluginManifest.api else {
      return .failure(session: request.session, id: request.id, error: RPCError.unsupportedAPI)
    }
    guard let method = PluginMethod(rawValue: request.method) else {
      return .failure(session: request.session, id: request.id, error: RPCError.unknownMethod)
    }
    guard var session = sessions[request.session] else {
      return .failure(session: request.session, id: request.id, error: RPCError.noSession)
    }
    let response: RPCResponse
    switch method {
    case .tabIndicators:
      guard session.reportsTabIndicators else {
        return .failure(session: request.session, id: request.id, error: RPCError.permissionDenied)
      }
      guard case .array(let values) = request.payload, values.count <= 512,
        let data = try? JSONEncoder().encode(request.payload),
        let items = try? JSONDecoder().decode([PluginTabIndicator].self, from: data),
        items.allSatisfy({ item in
          !item.target.host.isEmpty && item.target.host.utf8.count <= 255
            && item.target.host == item.target.host.lowercased()
            && item.target.terminal.hasPrefix("/dev/") && item.target.terminal.utf8.count <= 256
            && item.color <= 0xFFFFFF && !item.label.isEmpty && item.label.count <= 256
            && !item.target.host.contains(where: { $0.isWhitespace || $0.isNewline })
        }), Set(items.map(\.target)).count == items.count else {
        return .failure(session: request.session, id: request.id, error: RPCError.malformed)
      }
      tabIndicators?(request.session, session.pluginID, items)
      response = RPCResponse(session: request.session, id: request.id, ok: true, payload: .null)
    case .documentRead:
      response = readDocument(request, session: session)
    case .storageGet:
      response = await storage(request, session: &session, write: false)
    case .storageSet:
      response = await storage(request, session: &session, write: true)
    case .notify:
      response = await notify(request)
    case .ask:
      response = await ask(request)
    case .context:
      response = RPCResponse(session: request.session, id: request.id, ok: true, payload: session.environment.payload)
    case .reconnect:
      response = await reconnect(request)
    case .stream:
      response = await openStream(request, session: session)
    case .closeStream:
      guard let raw = request.payload.key("stream")?.string, let id = UUID(uuidString: raw),
        streams[id]?.session == request.session else {
        return .failure(session: request.session, id: request.id, error: "invalidStream")
      }
      streams.removeValue(forKey: id)?.task.cancel()
      response = RPCResponse(session: request.session, id: request.id, ok: true, payload: .null)
    case .status:
      guard session.reportsStatus else {
        return .failure(session: request.session, id: request.id, error: RPCError.permissionDenied)
      }
      status?(request.session, request.payload)
      response = RPCResponse(session: request.session, id: request.id, ok: true, payload: .null)
    }
    if (method == .storageGet || method == .storageSet), var current = sessions[request.session] {
      current.storageAsked = session.storageAsked
      current.storageAllowed = session.storageAllowed
      sessions[request.session] = current
    }
    return response
  }

  private func openStream(_ request: RPCRequest, session: Session) async -> RPCResponse {
    func failure(_ error: String) -> RPCResponse {
      .failure(session: request.session, id: request.id, error: error)
    }
    guard session.permissions.contains(.network),
      let text = request.payload.key("url")?.string, let url = URL(string: text),
      session.networkURLs.contains(url), NetworkEndpoint.valid(url) else {
      return failure(RPCError.permissionDenied)
    }
    // Runtime operations never prompt. Installation supplies the durable grant.
    guard networkGrants[session.pluginID]?.contains(url) == true else { return failure(RPCError.consentDenied) }
    guard !streams.values.contains(where: { $0.session == request.session }) else { return failure("streamLimit") }
    let id = UUID()
    let owner = request.session
    let task = Task { @MainActor [weak self, streaming] in
      // Return the stream id before delivering its first event.
      await Task.yield()
      do {
        try await streaming.stream(url: url) { [weak self] event in
          guard let self, self.sessions[owner] != nil, !Task.isCancelled else { return }
          await self.emit?(owner, .object(["stream": .string(id.uuidString), "type": .string("data"), "payload": event]))
        }
        guard !Task.isCancelled else { return }
        await self?.emit?(owner, .object(["stream": .string(id.uuidString), "type": .string("end")]))
      } catch {
        guard !Task.isCancelled else { return }
        await self?.emit?(owner, .object(["stream": .string(id.uuidString), "type": .string("error")]))
      }
      self?.streams[id] = nil
    }
    streams[id] = (owner, task)
    return RPCResponse(session: owner, id: request.id, ok: true, payload: .object(["stream": .string(id.uuidString)]))
  }

  private func readDocument(_ request: RPCRequest, session: Session) -> RPCResponse {
    guard session.permissions.contains(.documentRead) else {
      return .failure(session: request.session, id: request.id, error: RPCError.permissionDenied)
    }
    guard let raw = request.payload.key("handle")?.string, let handle = UUID(uuidString: raw) else {
      return .failure(session: request.session, id: request.id, error: RPCError.noGrant)
    }
    guard let bytes = session.documents[handle] else {
      return .failure(session: request.session, id: request.id, error: RPCError.invalidHandle)
    }
    return RPCResponse(
      session: request.session, id: request.id, ok: true,
      payload: .object(["bytes": .string(bytes.base64EncodedString())]))
  }

  private func storage(_ request: RPCRequest, session: inout Session, write: Bool) async -> RPCResponse {
    guard session.permissions.contains(.storagePlugin) else {
      return .failure(session: request.session, id: request.id, error: RPCError.permissionDenied)
    }
    if !session.storageAsked {
      let allowed = await consent.ask(pluginName: session.pluginName, permission: .storagePlugin)
      guard sessions[request.session] != nil else {
        return .failure(session: request.session, id: request.id, error: RPCError.noSession)
      }
      session.storageAllowed = allowed
      session.storageAsked = true
    }
    guard session.storageAllowed else {
      return .failure(session: request.session, id: request.id, error: RPCError.consentDenied)
    }
    guard let key = request.payload.key("key")?.string, !key.isEmpty, key.count <= 256 else {
      return .failure(session: request.session, id: request.id, error: RPCError.malformed)
    }
    if write {
      guard let value = request.payload.key("value")?.string, value.utf8.count <= 64 * 1024 else {
        return .failure(session: request.session, id: request.id, error: RPCError.malformed)
      }
      api.store(pluginID: session.pluginID, key: key, value: value)
      return RPCResponse(session: request.session, id: request.id, ok: true, payload: .object([:]))
    }
    let value = api.stored(pluginID: session.pluginID, key: key)
    return RPCResponse(
      session: request.session, id: request.id, ok: true,
      payload: .object(["value": value.map(JSONValue.string) ?? .null]))
  }

  private func notify(_ request: RPCRequest) async -> RPCResponse {
    guard let title = request.payload.key("title")?.string, !title.isEmpty, title.count <= 120 else {
      return .failure(session: request.session, id: request.id, error: RPCError.malformed)
    }
    let body = request.payload.key("body")?.string ?? ""
    guard body.count <= 240 else {
      return .failure(session: request.session, id: request.id, error: RPCError.malformed)
    }
    await api.notify(title: title, body: body)
    return RPCResponse(session: request.session, id: request.id, ok: true, payload: .object([:]))
  }

  private func ask(_ request: RPCRequest) async -> RPCResponse {
    guard let title = request.payload.key("title")?.string, !title.isEmpty, title.count <= 200 else {
      return .failure(session: request.session, id: request.id, error: RPCError.malformed)
    }
    var actions: [PluginAction] = []
    if case .array(let raw) = request.payload.key("actions") {
      for value in raw.prefix(4) {
        guard let id = value.key("id")?.string, !id.isEmpty, id.count <= 64,
          let name = value.key("title")?.string, !name.isEmpty, name.count <= 80 else { continue }
        actions.append(PluginAction(id: id, title: name, destructive: value.key("destructive")?.bool ?? false))
      }
    }
    if actions.isEmpty { actions = [.confirm("OK")] }
    let field: PluginField?
    if let label = request.payload.key("field")?.key("label")?.string {
      field = PluginField(
        label: String(label.prefix(80)),
        initial: String((request.payload.key("field")?.key("initial")?.string ?? "").prefix(1024)),
        secure: request.payload.key("field")?.key("secure")?.bool ?? false)
    } else {
      field = nil
    }
    let prompt = PluginPrompt(
      title: title, message: request.payload.key("message")?.string.map { String($0.prefix(240)) },
      field: field, actions: actions, cancel: String((request.payload.key("cancel")?.string ?? "Cancel").prefix(40)))
    let answer = await api.ask(prompt)
    return RPCResponse(
      session: request.session, id: request.id, ok: true,
      payload: .object([
        "action": answer.action.map(JSONValue.string) ?? .null,
        "value": .string(answer.value),
      ]))
  }

  private func reconnect(_ request: RPCRequest) async -> RPCResponse {
    guard let session = sessions[request.session] else {
      return .failure(session: request.session, id: request.id, error: RPCError.noSession)
    }
    guard let reconnect = session.reconnect else {
      return .failure(session: request.session, id: request.id, error: RPCError.unavailable)
    }
    do { try await reconnect() } catch {
      return .failure(session: request.session, id: request.id, error: RPCError.unavailable)
    }
    guard var current = sessions[request.session] else {
      return .failure(session: request.session, id: request.id, error: RPCError.noSession)
    }
    current.environment.connected = true
    sessions[request.session] = current
    return RPCResponse(session: request.session, id: request.id, ok: true, payload: current.environment.payload)
  }

  func read(pluginID: String, handle: UUID) async throws -> Data {
    guard let bytes = sessions.values.first(where: { $0.pluginID == pluginID && $0.documents[handle] != nil })?.documents[handle] else {
      throw PluginServiceError.unavailable
    }
    return bytes
  }

  func open(pluginID: String, url: URL) async throws -> UUID {
    guard let id = sessions.first(where: { $0.value.pluginID == pluginID })?.key,
      let session = sessions[id] else {
      throw PluginServiceError.unavailable
    }
    let response = await openStream(
      RPCRequest(session: id, id: "native", method: PluginMethod.stream.rawValue,
        payload: .object(["url": .string(url.absoluteString)])),
      session: session)
    guard response.ok, let raw = response.payload.key("stream")?.string, let stream = UUID(uuidString: raw) else {
      throw response.error == RPCError.consentDenied ? PluginServiceError.denied : PluginServiceError.unavailable
    }
    return stream
  }

  func close(pluginID: String, stream id: UUID) async {
    guard let owner = streams[id]?.session, sessions[owner]?.pluginID == pluginID else { return }
    streams.removeValue(forKey: id)?.task.cancel()
  }
}

extension PluginEnvironment {
  var payload: JSONValue {
    .object([
      "hostID": hostID.map { .string($0.uuidString) } ?? .null,
      "hostLabel": .string(hostLabel),
      "shellLabel": .string(shellLabel),
      "connected": .bool(connected),
    ])
  }
}
