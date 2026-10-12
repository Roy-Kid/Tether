import Foundation
import Testing

@testable import PortsPlugin

@Suite("what a port scan is allowed to say")
struct PortScanTests {
  @Test("nothing heard is an empty list")
  func empty() {
    #expect(PortScan.parse("") == [])
    #expect(PortScan.parse("\n") == [])
  }

  @Test("a bad line is skipped and the rest stand")
  func badLines() {
    let text = "nope\n8000\tlab\n\n80\tsshd\n12\tssh\nnot\ta\tport\n"
    #expect(PortScan.parse(text) == [HeardPort(port: 8000, name: "lab")])
  }

  @Test("past the cap, only the first sixty-four are kept")
  func overLimit() {
    let text = (1024..<1100).map { "\($0)\tname" }.joined(separator: "\n")
    let heard = PortScan.parse(text)
    #expect(heard?.count == 64)
    #expect(heard?.first?.port == 1024)
    #expect(heard?.last?.port == 1087)
  }

  @Test("a blob past the byte limit is refused whole")
  func tooLarge() {
    #expect(PortScan.parse(String(repeating: "8000\tx\n", count: 2_000)) == nil)
  }

  @Test("a repeated port is one row, and a name stays plain text")
  func onePortOneName() {
    let text = "8000\tmo\u{0007}lab\n8000\tother\n9000\tname\u{202E}exe"
    #expect(
      PortScan.parse(text) == [
        HeardPort(port: 8000, name: "molab"),
        HeardPort(port: 9000, name: "nameexe"),
      ])
  }

  @Test("only a socket this user can see, and not a privileged one")
  func onlyOwnSockets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-ports-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("net"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("10/fd"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("11/fd"), withIntermediateDirectories: true)
    let tcp = """
       sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        0: 0100007F:1F40 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1 0000000000000000 100 0 0 10 0
        1: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 222 1 0000000000000000 100 0 0 10 0
        2: 0100007F:1F41 00000000:0000 01 00000000:00000000 00:00000000 00000000  1000        0 333 1 0000000000000000 100 0 0 10 0
        3: 0100007F:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 444 1 0000000000000000 100 0 0 10 0
      """
    try tcp.write(to: root.appendingPathComponent("net/tcp"), atomically: true, encoding: .utf8)
    try "molab\n".write(to: root.appendingPathComponent("10/comm"), atomically: true, encoding: .utf8)
    try "sshd\n".write(to: root.appendingPathComponent("11/comm"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("10/fd/3").path, withDestinationPath: "socket:[111]")
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("11/fd/3").path, withDestinationPath: "socket:[222]")
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("10/fd/4").path, withDestinationPath: "socket:[333]")

    let output = try Self.run(root: root)
    #expect(PortScan.parse(output) == [HeardPort(port: 8000, name: "molab")])
    #expect(PortScan.command.contains("ps -u"))
  }

  @Test("an unreadable fd still lists a listener this user owns")
  func ownedWithoutFd() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-ports-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("net"), withIntermediateDirectories: true)
    let tcp = """
       sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        0: 0100007F:1F41 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 999 1 0000000000000000 100 0 0 10 0
      """
    try tcp.write(to: root.appendingPathComponent("net/tcp"), atomically: true, encoding: .utf8)
    let output = try Self.run(root: root, uid: "1000")
    #expect(PortScan.parse(output) == [HeardPort(port: 8001, name: "?")])
  }

  @Test("ss is enough: this user's listeners, not privileged or someone else's")
  func ssOwnsTheList() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-ss-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let ss = dir.appendingPathComponent("ss")
    try """
    #!/bin/sh
    echo 'State Recv-Q Send-Q Local Address:Port Peer Address:Port'
    echo 'LISTEN 0 128 127.0.0.1:5174 0.0.0.0:* users:(("node",pid=9,fd=3)) uid:1000 ino:1 sk:1'
    echo 'LISTEN 0 128 127.0.0.1:22 0.0.0.0:* uid:1000 ino:2 sk:2'
    echo 'LISTEN 0 128 [::1]:8001 *:* uid:1000 ino:3 sk:3'
    echo 'LISTEN 0 128 0.0.0.0:8000 0.0.0.0:* users:(("molab",pid=4,fd=5)) uid:1001 ino:4 sk:4'
    """.write(to: ss, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ss.path)
    let output = try Self.run(root: nil, uid: "1000", pathPrefix: dir.path)
    #expect(
      PortScan.parse(output) == [
        HeardPort(port: 5174, name: "node"),
        HeardPort(port: 8001, name: "?"),
      ])
  }

  private static func run(root: URL?, uid: String? = nil, pathPrefix: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", PortScan.command]
    var env = ProcessInfo.processInfo.environment
    if let root { env["TETHER_PROC_ROOT"] = root.path }
    if let uid { env["TETHER_PROC_UID"] = uid }
    if let pathPrefix { env["PATH"] = pathPrefix + ":" + (env["PATH"] ?? "/usr/bin:/bin") }
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let complaint = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, "\(complaint)\n\(text)")
    return text
  }
}
