import Foundation
import Testing
import Tether
import TetherPluginKit

@testable import FilesPlugin

/// Uploads over a real SSH session: Tether's own client, an OpenSSH server,
/// and the `sftp` subsystem that server runs.
///
/// Opt-in, because it needs a server: `TETHER_TEST_SSHD_PORT` names a port on
/// 127.0.0.1 where an `sshd` accepts the private key at `TETHER_TEST_SSHD_KEY`
/// for this user.
private final class Finished: @unchecked Sendable { var done = false }

@MainActor
@Suite("uploads over SSH", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["TETHER_TEST_SSHD_PORT"] != nil))
struct RemoteUploadTests {
  private struct TrustAll: HostTrust {
    func trusts(_ host: HostIdentity) async -> Bool { true }
  }

  private func connect() async throws -> TerminalSession {
    let environment = ProcessInfo.processInfo.environment
    let port = try #require(environment["TETHER_TEST_SSHD_PORT"].flatMap(UInt16.init))
    let key = try String(contentsOfFile: try #require(environment["TETHER_TEST_SSHD_KEY"]), encoding: .utf8)
    return try await TerminalSession.connect(
      to: Destination(host: "127.0.0.1", port: port, user: NSUserName()),
      trusting: TrustAll(), offering: [.privateKey(pem: key)])
  }

  private func context(_ connection: RemoteConnection?) -> TabContext {
    TabContext(
      id: UUID(),
      plugin: PluginContext(
        connection: connection, hostLabel: "lab", hostID: UUID(),
        openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
      focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
  }

  /// Fails instead of hanging the run.
  private func within<T: Sendable>(
    _ seconds: Double, _ what: String, _ body: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    let work = Task { @MainActor in try await body() }
    let deadline = ContinuousClock.now + .seconds(seconds)
    let box = Finished()
    Task { _ = try? await work.value; box.done = true }
    while !box.done, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard box.done else {
      work.cancel()
      Issue.record("\(what) did not finish within \(seconds) s")
      throw CancellationError()
    }
    return try await work.value
  }

  @Test("an upload through the files tab arrives on the far side", arguments: [12, 300_000, 5_000_000])
  func uploadArrives(size: Int) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-upload-\(UUID())")
    let destination = base.appendingPathComponent("remote", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await connect()
    defer { session.close() }
    let connection = try #require(session.connection)
    let model = FilesTab(
      tab: context(connection), cache: FileCache(host: UUID(), base: base), defaults: cleanDefaults())
    defer { model.close() }
    try await within(20, "listing") { await model.go(to: destination.path) }
    #expect(model.problem == nil)
    let payload = Data((0..<size).map { UInt8($0 % 251) })
    let local = base.appendingPathComponent("payload-\(size).bin")
    try payload.write(to: local)
    let arrived = try await within(60, "upload") { await model.upload([local], into: destination.path) }
    #expect(model.problem == nil)
    #expect(arrived == [destination.appendingPathComponent(local.lastPathComponent).path])
    #expect(try Data(contentsOf: destination.appendingPathComponent(local.lastPathComponent)) == payload)
  }
}
