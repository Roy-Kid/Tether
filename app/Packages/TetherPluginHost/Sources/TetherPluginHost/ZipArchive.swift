import Foundation
import zlib

/// A zip archive as GitHub publishes one: stored or deflated files, no links.
enum ZipArchive {
  static let entryLimit = 4096

  static func extract(_ data: Data, to directory: URL) throws {
    let bytes = [UInt8](data)
    guard let eocd = endOfCentralDirectory(bytes) else { throw PluginHostError.archiveUnreadable }
    let entries = Int(u16(bytes, eocd + 10))
    guard bytes.u16Fits(eocd + 4, value: 0), bytes.u16Fits(eocd + 6, value: 0),
      entries != 0xFFFF, entries <= entryLimit else {
      throw PluginHostError.archiveTooLarge
    }
    let size = Int(u32(bytes, eocd + 12))
    let offset = Int(u32(bytes, eocd + 16))
    guard size != 0xFFFFFFFF, offset != 0xFFFFFFFF, offset >= 0, size >= 0,
      offset <= bytes.count, size <= bytes.count - offset else { throw PluginHostError.archiveUnreadable }
    var cursor = offset
    let end = offset + size
    var seen: Set<String> = []
    var total = 0
    while cursor < end {
      guard u32(bytes, cursor) == 0x02014b50 else { throw PluginHostError.archiveUnreadable }
      guard cursor + 46 <= end else { throw PluginHostError.archiveUnreadable }
      let flags = u16(bytes, cursor + 8)
      let method = u16(bytes, cursor + 10)
      let crc = u32(bytes, cursor + 16)
      let compressed = u32(bytes, cursor + 20)
      let uncompressed = u32(bytes, cursor + 24)
      let nameLength = Int(u16(bytes, cursor + 28))
      let extraLength = Int(u16(bytes, cursor + 30))
      let commentLength = Int(u16(bytes, cursor + 32))
      let external = u32(bytes, cursor + 38)
      let local = Int(u32(bytes, cursor + 42))
      let madeBy = u16(bytes, cursor + 4) >> 8
      guard compressed != 0xFFFFFFFF, uncompressed != 0xFFFFFFFF, local != 0xFFFFFFFF else {
        throw PluginHostError.archiveTooLarge
      }
      let header = cursor + 46
      guard nameLength <= 256, header + nameLength + extraLength + commentLength <= end else {
        throw PluginHostError.archiveUnreadable
      }
      let name = Data(bytes[header..<(header + nameLength)])
      cursor = header + nameLength + extraLength + commentLength
      guard flags & 1 == 0 else { throw PluginHostError.archiveUnreadable }
      if madeBy == 3, (external >> 16) & 0o170000 == 0o120000 { throw PluginHostError.archiveUnreadable }
      let parts = try path(name)
      if parts.isEmpty { continue }
      let key = parts.joined(separator: "/")
      guard seen.insert(key).inserted else { throw PluginHostError.archiveUnreadable }
      let isDirectory = name.last == 0x2f
      if isDirectory {
        try FileManager.default.createDirectory(at: place(parts, in: directory), withIntermediateDirectories: true)
        continue
      }
      guard method == 0 || method == 8 else { throw PluginHostError.archiveUnreadable }
      let payload = try fileBytes(bytes, local: local, compressed: Int(compressed), flags: flags)
      let inflated: Data
      if method == 0 {
        guard payload.count == Int(uncompressed) else { throw PluginHostError.archiveUnreadable }
        inflated = payload
      } else {
        inflated = try inflate(payload, count: Int(uncompressed))
      }
      guard crc32(inflated) == crc else { throw PluginHostError.archiveUnreadable }
      guard inflated.count <= GitHubAPI.archiveLimit, total <= GitHubAPI.archiveLimit - inflated.count else {
        throw PluginHostError.archiveTooLarge
      }
      total += inflated.count
      let url = place(parts, in: directory)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try inflated.write(to: url, options: .atomic)
    }
  }

  private static func fileBytes(_ bytes: [UInt8], local: Int, compressed: Int, flags: UInt16) throws -> Data {
    guard local >= 0, local + 30 <= bytes.count, u32(bytes, local) == 0x04034b50 else {
      throw PluginHostError.archiveUnreadable
    }
    let nameLength = Int(u16(bytes, local + 26))
    let extraLength = Int(u16(bytes, local + 28))
    let start = local + 30 + nameLength + extraLength
    guard nameLength >= 0, extraLength >= 0, start >= 0, compressed >= 0, start <= bytes.count,
      compressed <= bytes.count - start else { throw PluginHostError.archiveUnreadable }
    if flags & 8 != 0, u32(bytes, local + 18) != 0, u32(bytes, local + 18) != UInt32(compressed) {
      throw PluginHostError.archiveUnreadable
    }
    return Data(bytes[start..<(start + compressed)])
  }

  private static func path(_ name: Data) throws -> [String] {
    guard let text = String(data: name, encoding: .utf8), !text.isEmpty, !text.hasPrefix("/"),
      !text.contains("\\"), !text.contains("\0"), text.utf8.count <= 256 else {
      throw PluginHostError.archiveUnreadable
    }
    var parts: [String] = []
    for part in text.split(separator: "/", omittingEmptySubsequences: false) {
      if part.isEmpty { continue }
      guard part != ".", part != "..", !part.contains(":") else { throw PluginHostError.archiveUnreadable }
      parts.append(String(part))
    }
    return parts
  }

  private static func place(_ parts: [String], in directory: URL) -> URL {
    parts.reduce(directory) { $0.appending(path: $1) }
  }

  private static func inflate(_ source: Data, count: Int) throws -> Data {
    guard count >= 0, count <= GitHubAPI.archiveLimit else { throw PluginHostError.archiveTooLarge }
    if count == 0 { return Data() }
    var stream = z_stream()
    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw PluginHostError.archiveUnreadable
    }
    defer { inflateEnd(&stream) }
    var output = Data(count: count)
    let status: Int32 = source.withUnsafeBytes { raw in
      output.withUnsafeMutableBytes { out in
        stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(source.count)
        stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(count)
        return zlib.inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END, stream.total_out == uLong(count) else { throw PluginHostError.archiveUnreadable }
    return output
  }

  private static func crc32(_ data: Data) -> UInt32 {
    let value = data.withUnsafeBytes { raw -> uLong in
      guard let base = raw.bindMemory(to: Bytef.self).baseAddress, !data.isEmpty else { return 0 }
      return zlib.crc32(0, base, uInt(data.count))
    }
    return UInt32(value & 0xFFFFFFFF)
  }

  private static func endOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 22 else { return nil }
    let start = max(0, bytes.count - 22 - 65_535)
    var index = bytes.count - 22
    while index >= start {
      if u32(bytes, index) == 0x06054b50, index + 22 + Int(u16(bytes, index + 20)) == bytes.count {
        return index
      }
      if index == 0 { break }
      index -= 1
    }
    return nil
  }

  private static func u16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
    guard index >= 0, index + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
  }

  private static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
    guard index >= 0, index + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
      | UInt32(bytes[index + 3]) << 24
  }
}

private extension Array where Element == UInt8 {
  func u16Fits(_ index: Int, value: UInt16) -> Bool {
    guard index >= 0, index + 2 <= count else { return false }
    let found = UInt16(self[index]) | UInt16(self[index + 1]) << 8
    return found == value
  }
}
