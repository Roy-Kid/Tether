import Foundation
#if os(macOS)
import Darwin
#endif

/// The program in front of a local shell, for the terminal's chip.
///
/// A remote shell has no process on this machine. Its name comes from an
/// attached session or from the directory it reports, not from here.
enum LocalForeground {
  /// Waiting shells are the prompt, not work. The same set the close check uses.
  static let shells: Set<String> = [
    "sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "ksh93", "mksh", "csh", "tcsh",
    "nu", "elvish", "xonsh",
  ]

  /// Nil when `shellPID` is the foreground, or when this machine cannot say.
  static func command(shellPID: UInt32?) -> String? {
    guard let shellPID, let shell = process(shellPID) else { return nil }
    let group = shell.pgid == 0 ? shellPID : shell.pgid
    return picked(shellPGID: group, foreground: shell.tpgid, leader: process(shell.tpgid)?.name)
  }

  /// `foreground` is the terminal's foreground process group. It matches the
  /// shell's group while the prompt is waiting.
  static func picked(shellPGID: UInt32, foreground: UInt32, leader: String?) -> String? {
    guard foreground != 0, foreground != shellPGID else { return nil }
    guard let leader else { return nil }
    var bare = URL(fileURLWithPath: leader).lastPathComponent
    if bare.hasPrefix("-") { bare.removeFirst() }
    guard !bare.isEmpty, !shells.contains(bare) else { return nil }
    return bare
  }

  #if os(macOS)
  private struct Process {
    var pgid: UInt32
    var tpgid: UInt32
    var name: String
  }

  /// The registered name of `pid`, for tests that only need the read to work.
  static func leaderName(pid: UInt32) -> String? { process(pid)?.name }

  private static func process(_ pid: UInt32) -> Process? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let wrote = proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size)
    guard wrote == size else { return nil }
    let registered = text(info.pbi_name)
    let name = registered.isEmpty ? text(info.pbi_comm) : registered
    return Process(pgid: info.pbi_pgid, tpgid: info.e_tpgid, name: name)
  }

  private static func text<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
      return String(decoding: bytes[..<end], as: UTF8.self)
    }
  }
  #else
  private struct Process {
    var pgid: UInt32
    var tpgid: UInt32
    var name: String
  }

  static func leaderName(pid: UInt32) -> String? { nil }

  private static func process(_ pid: UInt32) -> Process? { nil }
  #endif
}
