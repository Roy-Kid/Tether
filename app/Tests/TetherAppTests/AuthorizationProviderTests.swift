#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import TetherApp

@MainActor
@Suite("Remote public key enrollment")
struct AuthorizationProviderTests {
  @Test func enrollmentIsIdempotentAndRevocationPreservesOtherKeys() throws {
    let path = temporaryFile("authorized_keys")
    defer { removeDirectory(of: path) }
    let credentials = DeviceCredentialStore(secrets: MemorySecrets())
    let key = try credentials.generateSSHKey(id: UUID(), label: "Fixture")
    let request = RemoteAuthorization(hostID: UUID(), publicKey: key, deviceLabel: "Phone",
      provider: "authorized_keys", state: .installed)
    let original = "# Administrator entry\nssh-ed25519 unrelated administrator\n"
    try original.write(to: path, atomically: true, encoding: .utf8)
    func run(remove: Bool) throws {
      let script = try AuthorizedKeysProvider.script(request, remove: remove)
        .replacingOccurrences(of: "d=\"$HOME/.ssh\"", with: "d=" + shellQuoted(path.deletingLastPathComponent().path))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", script]
      try process.run(); process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
    try run(remove: false)
    try run(remove: false)
    let installed = try String(contentsOf: path, encoding: .utf8)
    #expect(installed.hasPrefix(original))
    #expect(installed.components(separatedBy: "tether:" + request.id.uuidString).count == 2)
    try run(remove: true)
    #expect(try String(contentsOf: path, encoding: .utf8) == original)
  }

  @Test func generatedPrivateKeyIsReadableByOpenSSH() throws {
    let path = temporaryFile("fixture-key")
    defer { removeDirectory(of: path) }
    let credentials = DeviceCredentialStore(secrets: MemorySecrets())
    let id = UUID()
    let publicKey = try credentials.generateSSHKey(id: id, label: "Fixture")
    try credentials.read(id).write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let process = Process(); let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-y", "-f", path.path]
    process.standardOutput = output
    try process.run()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == (try AuthorizedKeysProvider.keyMaterial(publicKey)))
  }
}
#endif
