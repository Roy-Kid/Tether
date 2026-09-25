import Foundation
import Testing

@testable import FilesPlugin

@Suite("peeks at files")
struct FilePreviewTests {
  @Test("a text file peeks as a snippet, with hostile bytes cleaned")
  func textSnippet() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-\(UUID().uuidString).txt")
    try Data("hello\n\u{1B}[31mred\u{0}\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let snippet = try #require(FilePreview.textSnippet(at: url))
    #expect(snippet.hasPrefix("hello\n"))
    #expect(snippet.contains("�"))
    #expect(!snippet.contains("\u{1B}"))
    #expect(!snippet.contains("\u{0}"))
  }

  @Test("a long file peeks only the head, and says so")
  func truncatedSnippet() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-\(UUID().uuidString).log")
    try Data(String(repeating: "a", count: 10_000).utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let snippet = try #require(FilePreview.textSnippet(at: url))
    #expect(snippet.hasSuffix("…"))
    #expect(snippet.count <= FilePreview.textLimit + 2)
  }

  @Test("an empty file peeks as empty, not as missing")
  func emptySnippet() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-\(UUID().uuidString).txt")
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(FilePreview.textSnippet(at: url) == "")
  }
}
