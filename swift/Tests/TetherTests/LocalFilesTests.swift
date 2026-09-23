import Foundation
import Testing
import Tether

/// Where OpenSSH installs its SFTP server. A skip rather than a failure where
/// there is none: it is not a dependency of Tether.
private let sftpServerIsInstalled: Bool = [
  "/usr/libexec/sftp-server",
  "/usr/lib/openssh/sftp-server",
  "/usr/libexec/openssh/sftp-server",
  "/usr/lib/ssh/sftp-server",
].contains { FileManager.default.isExecutableFile(atPath: $0) }

private final class Scratch {
  let url: URL
  init(_ name: String) throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .resolvingSymlinksInPath()
      .appendingPathComponent("tether-swift-files-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
  func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }
  deinit { try? FileManager.default.removeItem(at: url) }
}

private final class Progress: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: UInt64 = 0
  func record(_ bytes: UInt64) { lock.withLock { latest = bytes } }
  var value: UInt64 { lock.withLock { latest } }
}

/// Swift → a local shell's lease → SFTP, with the same calls a browser over
/// a remote session makes.
@Test(
  "Swift → a local lease → files: list, copy both ways, refuse to replace, remove",
  .enabled(if: sftpServerIsInstalled))
func localFilesRoundTrip() async throws {
  let shell = try await TerminalSession.local()
  defer { shell.close() }
  let connection = try #require(shell.connection)
  let files = try await connection.files()
  #expect(files.isLocal)
  let scratch = try Scratch("roundtrip")
  try Data("hello".utf8).write(to: URL(fileURLWithPath: scratch.path("hello.txt")))

  let listed = try await files.list(scratch.path(""))
  #expect(listed.map(\.name) == ["hello.txt"])
  #expect(listed.first?.kind == .file)

  let progress = Progress()
  let copied = try await files.download(
    scratch.path("hello.txt"), to: scratch.path("copy.txt"),
    progress: { progress.record($0) })
  #expect(copied == 5)
  #expect(progress.value == 5)

  await #expect(throws: FileError.exists(path: scratch.path("hello.txt"))) {
    _ = try await files.upload(scratch.path("copy.txt"), to: scratch.path("hello.txt"))
  }
  _ = try await files.upload(
    scratch.path("copy.txt"), to: scratch.path("hello.txt"), replacing: true)

  try await files.makeDirectory(scratch.path("inner"))
  try await files.rename(scratch.path("copy.txt"), to: scratch.path("inner/copy.txt"))
  #expect(try await files.removeTree(scratch.path("inner")) == 2)
  await #expect(throws: FileError.notFound(path: scratch.path("inner"))) {
    _ = try await files.stat(scratch.path("inner"))
  }
  await files.close()
}

@Test("A file error says what happened in words")
func fileErrorsDescribeThemselves() {
  #expect(FileError.notEmpty(path: "/tmp/x").errorDescription == "“x” is not empty.")
  #expect(FileError.cancelled.errorDescription == "Cancelled.")
}
