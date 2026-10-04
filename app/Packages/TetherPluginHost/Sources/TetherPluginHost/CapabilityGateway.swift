import Foundation

public enum PluginHostError: Error, Equatable {
  case package(PackageFailure)
  case duplicate(String)
  case unknownPlugin(String)
  case disabled(String)
  case consentDenied
  case noSession
  case permissionDenied
}

@MainActor
final class CapabilityGateway {
  private struct Session {
    let pluginID: String
    let pluginName: String
    let permissions: Set<Permission>
    var documents: [UUID: Data] = [:]
    var storageAsked = false
    var storageAllowed = false
  }

  private let consent: any ConsentAsking
  private let notifying: any HostNotifying
  private var sessions: [UUID: Session] = [:]
  private var storage: [String: [String: String]] = [:]

  init(consent: any ConsentAsking, notifying: any HostNotifying) {
    self.consent = consent
    self.notifying = notifying
  }

  func open(_ id: UUID, record: PluginRecord) {
    sessions[id] = Session(
      pluginID: record.id, pluginName: record.manifest.name,
      permissions: Set(record.manifest.permissions))
  }

  func close(_ id: UUID) {
    sessions[id] = nil
  }

  func pluginID(for session: UUID) -> String? {
    sessions[session]?.pluginID
  }

  func sessions(for pluginID: String) -> [UUID] {
    sessions.compactMap { $0.value.pluginID == pluginID ? $0.key : nil }
  }

  func wipeStorage(pluginID: String) {
    storage[pluginID] = nil
  }

  func grant(session id: UUID, bytes: Data) async throws -> DocumentHandle {
    guard var session = sessions[id] else { throw PluginHostError.noSession }
    guard session.permissions.contains(.documentRead) else { throw PluginHostError.permissionDenied }
    let allowed = await consent.ask(pluginName: session.pluginName, permission: .documentRead)
    guard sessions[id] != nil else { throw PluginHostError.noSession }
    guard allowed else { throw PluginHostError.consentDenied }
    let handle = DocumentHandle()
    session.documents[handle.id] = bytes
    sessions[id] = session
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
    case .documentRead:
      response = readDocument(request, session: session)
    case .storageGet:
      response = await storage(request, session: &session, write: false)
    case .storageSet:
      response = await storage(request, session: &session, write: true)
    case .notify:
      response = await notify(request)
    }
    if sessions[request.session] != nil {
      sessions[request.session] = session
    }
    return response
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
      var bucket = storage[session.pluginID] ?? [:]
      bucket[key] = value
      storage[session.pluginID] = bucket
      return RPCResponse(session: request.session, id: request.id, ok: true, payload: .object([:]))
    }
    let value = storage[session.pluginID]?[key]
    return RPCResponse(
      session: request.session, id: request.id, ok: true,
      payload: .object(["value": value.map(JSONValue.string) ?? .null]))
  }

  private func notify(_ request: RPCRequest) async -> RPCResponse {
    guard let title = request.payload.key("title")?.string, !title.isEmpty else {
      return .failure(session: request.session, id: request.id, error: RPCError.malformed)
    }
    await notifying.notify(title: title)
    return RPCResponse(session: request.session, id: request.id, ok: true, payload: .object([:]))
  }
}
