import Foundation
import Testing
import TetherPluginKit
import zlib

@testable import TetherPluginHost

@Test func aRepositoryAddressIsOwnerAndName() {
  #expect(GitHubRepository.parse("https://github.com/Acme/plugin")?.owner == "Acme")
  #expect(GitHubRepository.parse("https://github.com/Acme/plugin")?.name == "plugin")
  #expect(GitHubRepository.parse("http://www.github.com/Acme/plugin.git/")?.name == "plugin")
  #expect(GitHubRepository.parse("github.com/Acme/plugin?tab=readme")?.owner == "Acme")
  #expect(GitHubRepository.parse("https://github.com/Acme/plugin/tree/main") == nil)
  #expect(GitHubRepository.parse("https://gist.github.com/Acme/plugin") == nil)
  #expect(GitHubRepository.parse("https://gitlab.com/Acme/plugin") == nil)
  #expect(GitHubRepository.parse("Acme/plugin") == nil)
}

@Test func latestReleaseTagIsASingleName() throws {
  let tagged = Data(#"{"tag_name":"v1.2.3","zipball_url":"https://evil.example/zip"}"#.utf8)
  #expect(GitHubTag.read(from: tagged) == "v1.2.3")
  #expect(GitHubTag.read(from: Data(#"{"tag_name":"v1/beta"}"#.utf8)) == nil)
  #expect(GitHubTag.check("..") == false)
  #expect(GitHubHosts.allows("codeload.github.com"))
  #expect(!GitHubHosts.allows("codeload.github.com.evil.com"))
  #expect(!GitHubHosts.allows("objects.githubusercontent.com"))
}

@Test func aStoredArchiveRoundTripsAndADeflatedOneDoesToo() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let stored = ZipBuilder.archive([
    .init(name: "repo-v1/manifest.json", bytes: Data("{\"id\":\"ok\"}".utf8)),
    .init(name: "repo-v1/web/index.html", bytes: Data("hello".utf8)),
  ])
  try ZipArchive.extract(stored, to: directory)
  let page = directory.appending(path: "repo-v1/web/index.html")
  #expect(try Data(contentsOf: page) == Data("hello".utf8))

  let deflated = ZipBuilder.archive([
    .init(name: "note.txt", bytes: Data("hello".utf8), method: 8),
  ])
  let plain = directory.appending(path: "plain")
  try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
  try ZipArchive.extract(deflated, to: plain)
  #expect(try Data(contentsOf: plain.appending(path: "note.txt")) == Data("hello".utf8))
}

@Test func anArchiveCannotLeaveItsDirectoryOrCarryALink() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: "zip-escape-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let escaped = ZipBuilder.archive([.init(name: "../outside.txt", bytes: Data("x".utf8))])
  #expect(throws: PluginHostError.archiveUnreadable) { try ZipArchive.extract(escaped, to: directory) }
  #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appending(path: "outside.txt").path))

  let link = ZipBuilder.archive([
    .init(name: "link", bytes: Data(), madeBy: (3 << 8) | 20, external: UInt32(0o120777) << 16),
  ])
  #expect(throws: PluginHostError.archiveUnreadable) { try ZipArchive.extract(link, to: directory) }
  #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "link").path))
}

@Test @MainActor func aGitHubAddressInstallsTheArchiveItWasGiven() async throws {
  let source = try Fixture.make(id: "fixture.github")
  let directory = FileManager.default.temporaryDirectory.appending(path: "lib-\(UUID().uuidString)")
  defer {
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: directory)
  }
  let archive = ZipBuilder.archive([
    .init(name: "repo-v1/manifest.json", bytes: try Data(contentsOf: source.appending(path: "manifest.json"))),
    .init(name: "repo-v1/web/index.html", bytes: try Data(contentsOf: source.appending(path: "web/index.html"))),
  ])
  let fetch = FixedArchive(data: archive)
  let registry = TetherPluginKit.PluginRegistry(defaults: UserDefaults(suiteName: UUID().uuidString)!)
  let library = InstalledPlugins(
    directory: directory, registry: registry,
    host: PluginHost(consent: ScriptedConsent(allow: true), presenting: RecordedPresenter()))
  let installed = try await library.install(repository: "https://github.com/Acme/plugin.git", fetch: fetch)
  #expect(fetch.seen?.0 == "Acme")
  #expect(fetch.seen?.1 == "plugin")
  #expect(installed.id == "fixture.github")
  #expect(registry.plugins.map(\.metadata.id) == ["fixture.github"])
  await #expect(throws: PluginHostError.notARepository) {
    try await library.install(repository: "https://github.com/Acme/plugin/tree/main", fetch: fetch)
  }
  await #expect(throws: PluginHostError.noRelease) {
    try await library.install(repository: "github.com/Acme/empty", fetch: EmptyRelease())
  }
}

private struct ZipItem {
  var name: String
  var bytes: Data
  var method: UInt16 = 0
  var madeBy: UInt16 = 20
  var external: UInt32 = 0
}

private enum ZipBuilder {
  static func archive(_ items: [ZipItem]) -> Data {
    var locals = Data()
    var central = Data()
    for item in items {
      let name = Data(item.name.utf8)
      let compressed = item.method == 8 ? rawDeflate(item.bytes) : item.bytes
      var local = Data()
      local.appendU32(0x04034b50)
      local.appendU16(20)
      local.appendU16(1 << 11)
      local.appendU16(item.method)
      local.appendU16(0)
      local.appendU16(0)
      local.appendU32(checksum(item.bytes))
      local.appendU32(UInt32(compressed.count))
      local.appendU32(UInt32(item.bytes.count))
      local.appendU16(UInt16(name.count))
      local.appendU16(0)
      local.append(name)
      let offset = UInt32(locals.count)
      locals.append(local)
      locals.append(compressed)

      var entry = Data()
      entry.appendU32(0x02014b50)
      entry.appendU16(item.madeBy)
      entry.appendU16(20)
      entry.appendU16(1 << 11)
      entry.appendU16(item.method)
      entry.appendU16(0)
      entry.appendU16(0)
      entry.appendU32(checksum(item.bytes))
      entry.appendU32(UInt32(compressed.count))
      entry.appendU32(UInt32(item.bytes.count))
      entry.appendU16(UInt16(name.count))
      entry.appendU16(0)
      entry.appendU16(0)
      entry.appendU16(0)
      entry.appendU16(0)
      entry.appendU32(item.external)
      entry.appendU32(offset)
      entry.append(name)
      central.append(entry)
    }
    var end = Data()
    end.appendU32(0x06054b50)
    end.appendU16(0)
    end.appendU16(0)
    end.appendU16(UInt16(items.count))
    end.appendU16(UInt16(items.count))
    end.appendU32(UInt32(central.count))
    end.appendU32(UInt32(locals.count))
    end.appendU16(0)
    return locals + central + end
  }

  private static func checksum(_ data: Data) -> UInt32 {
    let value = data.withUnsafeBytes { raw -> uLong in
      guard let base = raw.bindMemory(to: Bytef.self).baseAddress, !data.isEmpty else { return 0 }
      return zlib.crc32(0, base, uInt(data.count))
    }
    return UInt32(value & 0xFFFFFFFF)
  }

  private static func rawDeflate(_ input: Data) -> Data {
    var stream = z_stream()
    guard deflateInit2_(
      &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
      Int32(MemoryLayout<z_stream>.size)
    ) == Z_OK else { return Data() }
    defer { deflateEnd(&stream) }
    let bound = Int(deflateBound(&stream, uLong(input.count)))
    var output = Data(count: bound)
    let status: Int32 = input.withUnsafeBytes { raw in
      output.withUnsafeMutableBytes { out in
        stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(bound)
        return zlib.deflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END else { return Data() }
    return output.prefix(Int(stream.total_out))
  }
}

private extension Data {
  mutating func appendU16(_ value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8(value >> 8))
  }

  mutating func appendU32(_ value: UInt32) {
    appendU16(UInt16(value & 0xFFFF))
    appendU16(UInt16(value >> 16))
  }
}

private final class FixedArchive: ReleaseArchiveFetching, @unchecked Sendable {
  let data: Data
  var seen: (String, String)?
  init(data: Data) { self.data = data }
  func latestArchive(owner: String, repository: String) async throws -> Data {
    seen = (owner, repository)
    return data
  }
}

private struct EmptyRelease: ReleaseArchiveFetching {
  func latestArchive(owner: String, repository: String) async throws -> Data {
    throw PluginHostError.noRelease
  }
}
