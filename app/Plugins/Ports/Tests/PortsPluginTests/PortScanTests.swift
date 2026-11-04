import Foundation
import Testing

@testable import PortsPlugin

@Suite("what a port scan is allowed to say")
struct PortScanTests {

  @Test("a bad line is skipped and the rest stand")
  func badLines() {
    let text = "nope\n8000\tlab\n\n80\tsshd\n12\tssh\nnot\ta\tport\n"
    #expect(PortScan.parse(text) == [HeardPort(port: 8000, name: "lab")])
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
