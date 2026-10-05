import Foundation

public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public func key(_ name: String) -> JSONValue? {
    if case .object(let fields) = self { return fields[name] }
    return nil
  }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

/// Methods the bridge will forward. Anything else is rejected before a host service runs.
public enum PluginMethod: String, Sendable, Equatable, CaseIterable {
  case documentRead = "document.read"
  case storageGet = "storage.plugin.get"
  case storageSet = "storage.plugin.set"
  case notify = "host.notify"
}

public struct RPCRequest: Sendable, Equatable, Codable {
  public var api: Int
  public var session: UUID
  public var id: String
  public var method: String
  public var payload: JSONValue

  public init(api: Int = PluginManifest.api, session: UUID, id: String, method: String, payload: JSONValue) {
    self.api = api
    self.session = session
    self.id = id
    self.method = method
    self.payload = payload
  }
}

public struct RPCResponse: Sendable, Equatable, Codable {
  public var api: Int
  public var session: UUID
  public var id: String
  public var ok: Bool
  public var payload: JSONValue
  public var error: String?

  public init(api: Int = PluginManifest.api, session: UUID, id: String, ok: Bool, payload: JSONValue, error: String? = nil) {
    self.api = api
    self.session = session
    self.id = id
    self.ok = ok
    self.payload = payload
    self.error = error
  }

  public static func failure(session: UUID, id: String, error: String) -> RPCResponse {
    RPCResponse(session: session, id: id, ok: false, payload: .null, error: error)
  }
}

enum RPCCodec {
  static func encode<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
  }

  static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
  }

  /// The page does not choose which session it speaks as.
  static func pin(_ text: String, to session: UUID) -> String {
    guard var request = try? decode(RPCRequest.self, from: text) else { return text }
    request.session = session
    return (try? encode(request)) ?? text
  }
}

enum RPCError {
  static let malformed = "malformed"
  static let unsupportedAPI = "unsupportedAPI"
  static let unknownMethod = "unknownMethod"
  static let noSession = "noSession"
  static let permissionDenied = "permissionDenied"
  static let consentDenied = "consentDenied"
  static let invalidHandle = "invalidHandle"
  static let noGrant = "noGrant"
}
