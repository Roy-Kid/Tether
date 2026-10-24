import Foundation

/// Exact endpoints, not origins. Plain HTTP is limited to literal loopback.
public enum NetworkEndpoint {
  /// `scheme://host:port`, so a granted loopback stream can cover refresh and clear
  /// on that same port without granting a new machine.
  public static func origin(_ url: URL) -> String? {
    guard let host = url.host, let scheme = url.scheme else { return nil }
    let port = url.port ?? (scheme == "https" ? 443 : 80)
    return "\(scheme)://\(host):\(port)"
  }

  /// Declared URLs whose origin was already approved. New origins stay unapproved.
  public static func expandGrants(declared: [URL], approved: Set<String>) -> Set<String> {
    var origins = Set<String>()
    for raw in approved {
      if let url = URL(string: raw), let key = origin(url) { origins.insert(key) }
    }
    var expanded = approved
    for url in declared {
      if let key = origin(url), origins.contains(key) { expanded.insert(url.absoluteString) }
      }
    return expanded
  }

  public static func valid(_ url: URL) -> Bool {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.user == nil, parts.password == nil, parts.fragment == nil,
      let host = parts.host, !host.isEmpty else { return false }
    return parts.scheme == "https"
      || (parts.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host))
  }
}

/// A bounded SSE decoder. Comments are heartbeats; data lines join with newlines.
struct EventStreamDecoder {
  static let limit = 2 * 1024 * 1024
  private var line = Data()
  private var data: [String] = []
  private var size = 0
  private var event = "message"

  mutating func append(_ byte: UInt8) throws -> JSONValue? {
    if byte != 10 {
      guard line.count < Self.limit else { throw StreamFailure.tooLarge }
      line.append(byte)
      return nil
    }
    if line.last == 13 { line.removeLast() }
    let text = String(decoding: line, as: UTF8.self)
    line.removeAll(keepingCapacity: true)
    if text.isEmpty {
      defer { data.removeAll(keepingCapacity: true); size = 0; event = "message" }
      guard !data.isEmpty else { return nil }
      return .object(["event": .string(event), "data": .string(data.joined(separator: "\n"))])
    }
    if text.hasPrefix(":") { return nil }
    let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    var value = pieces.count == 2 ? String(pieces[1]) : ""
    if value.hasPrefix(" ") { value.removeFirst() }
    if pieces[0] == "data" {
      size += value.utf8.count + 1
      guard size <= Self.limit else { throw StreamFailure.tooLarge }
      data.append(value)
    } else if pieces[0] == "event" { event = value }
    return nil
  }
}

enum StreamFailure: Error { case tooLarge, invalidResponse }

/// Injectable so capability and cancellation tests need no live server.
@MainActor
public protocol PluginStreaming: AnyObject {
  func stream(url: URL, receive: @escaping @MainActor (JSONValue) async -> Void) async throws
}

/// One POST with an empty body. Refresh and clear are this shape.
@MainActor
public protocol PluginPosting: AnyObject {
  func post(url: URL) async throws
}

@MainActor
public final class HTTPPoster: PluginPosting {
  public init() {}
  public func post(url: URL) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    let (_, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      throw StreamFailure.invalidResponse
    }
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

@MainActor
public final class HTTPEventStream: PluginStreaming {
  public init() {}
  @concurrent public func stream(url: URL, receive: @escaping @MainActor (JSONValue) async -> Void) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 24 * 60 * 60
    let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.mimeType == "text/event-stream" else { throw StreamFailure.invalidResponse }
    var decoder = EventStreamDecoder()
    for try await byte in bytes {
      try Task.checkCancellation()
      if let event = try decoder.append(byte) { await receive(event) }
    }
  }
}
