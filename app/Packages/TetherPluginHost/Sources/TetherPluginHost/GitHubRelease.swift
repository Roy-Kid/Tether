import Foundation

/// `github.com/owner/repo`, and nothing after it. A query or fragment is ignored.
enum GitHubRepository: Equatable {
  static func parse(_ text: String) -> (owner: String, name: String)? {
    var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("https://") { raw.removeFirst("https://".count) }
    else if raw.hasPrefix("http://") { raw.removeFirst("http://".count) }
    let lowered = raw.lowercased()
    if lowered.hasPrefix("www.") { raw.removeFirst("www.".count) }
    guard raw.lowercased().hasPrefix("github.com/") else { return nil }
    raw.removeFirst("github.com/".count)
    if let cut = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) { raw = String(raw[..<cut]) }
    while raw.hasSuffix("/") { raw.removeLast() }
    if raw.lowercased().hasSuffix(".git") { raw.removeLast(".git".count) }
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, validOwner(parts[0]), validName(parts[1]) else { return nil }
    return (parts[0], parts[1])
  }

  private static func validOwner(_ value: String) -> Bool {
    guard (1...39).contains(value.count), !value.hasPrefix("-"), !value.hasSuffix("-") else { return false }
    return value.unicodeScalars.allSatisfy { character($0) || $0 == "-" }
  }

  private static func validName(_ value: String) -> Bool {
    guard (1...100).contains(value.count), value != ".", value != ".." else { return false }
    return value.unicodeScalars.allSatisfy { character($0) || $0 == "-" || $0 == "_" || $0 == "." }
  }

  private static func character(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    return (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
  }
}

enum GitHubHosts {
  static func allows(_ host: String) -> Bool {
    switch host.lowercased() {
    case "api.github.com", "codeload.github.com", "github.com": true
    default: false
    }
  }
}

enum GitHubTag {
  static func check(_ tag: String) -> Bool {
    guard (1...128).contains(tag.count), tag != ".", tag != "..", !tag.contains("..") else { return false }
    return tag.unicodeScalars.allSatisfy { scalar in
      let value = scalar.value
      return (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
        || value == 45 || value == 46 || value == 95
    }
  }

  static func read(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = object["tag_name"] as? String, check(tag) else { return nil }
    return tag
  }
}

protocol ReleaseArchiveFetching: Sendable {
  func latestArchive(owner: String, repository: String) async throws -> Data
}

/// The latest non-prerelease GitHub release, as the repository's source archive.
struct GitHubLatestRelease: ReleaseArchiveFetching {
  func latestArchive(owner: String, repository: String) async throws -> Data {
    let tag = try await GitHubAPI.latestTag(owner: owner, repository: repository)
    return try await GitHubAPI.zipball(owner: owner, repository: repository, tag: tag)
  }
}

enum GitHubAPI {
  static let archiveLimit = 32 * 1024 * 1024

  static func latestTag(owner: String, repository: String) async throws -> String {
    let url = try endpoint("/repos/\(owner)/\(repository)/releases/latest")
    let (status, data) = try await get(url, accept: "application/vnd.github+json", limit: 1024 * 1024)
    if status == 404 { throw PluginHostError.noRelease }
    guard status == 200, let tag = GitHubTag.read(from: data) else { throw PluginHostError.remoteUnavailable }
    return tag
  }

  static func zipball(owner: String, repository: String, tag: String) async throws -> Data {
    guard GitHubTag.check(tag) else { throw PluginHostError.remoteUnavailable }
    let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
    let url = try endpoint("/repos/\(owner)/\(repository)/zipball/\(encoded)")
    let (status, data) = try await get(url, accept: "application/octet-stream", limit: archiveLimit)
    guard status == 200, !data.isEmpty else { throw PluginHostError.remoteUnavailable }
    return data
  }

  private static func endpoint(_ path: String) throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "api.github.com"
    components.path = path
    guard let url = components.url else { throw PluginHostError.remoteUnavailable }
    return url
  }

  private static func get(_ url: URL, accept: String, limit: Int) async throws -> (Int, Data) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    let session = URLSession(configuration: configuration, delegate: GitHubRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("Tether", forHTTPHeaderField: "User-Agent")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw PluginHostError.remoteUnavailable }
      if let length = http.value(forHTTPHeaderField: "Content-Length"), let count = Int(length), count > limit {
        throw PluginHostError.archiveTooLarge
      }
      var data = Data()
      var chunk: [UInt8] = []
      chunk.reserveCapacity(16 * 1024)
      for try await byte in bytes {
        try Task.checkCancellation()
        chunk.append(byte)
        if chunk.count == 16 * 1024 {
          try append(&data, chunk, limit: limit)
          chunk.removeAll(keepingCapacity: true)
        }
      }
      try append(&data, chunk, limit: limit)
      return (http.statusCode, data)
    } catch let error as PluginHostError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PluginHostError.remoteUnavailable
    }
  }

  private static func append(_ data: inout Data, _ chunk: [UInt8], limit: Int) throws {
    guard data.count <= limit - chunk.count else { throw PluginHostError.archiveTooLarge }
    data.append(contentsOf: chunk)
  }
}

private final class GitHubRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
      let host = url.host, GitHubHosts.allows(host) else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
