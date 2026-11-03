import Foundation

#if os(macOS)
  import SystemConfiguration
#endif

/// This Mac as a terminal's machine: its Bonjour name, `<LocalHostName>.local`,
/// lowercased. A status hub names this Mac's jobs the same way. The kernel's
/// hostname is not it: a Mac takes that from whatever network it is on, so a
/// tab and the agent in it would name two machines after a reconnect.
///
/// Read once, as the hub reads it once: a rename is seen by both after a
/// restart.
enum LocalMachine {
  static let name: String = resolve(bonjour: bonjourName, kernel: kernelName)

  static func resolve(bonjour: String?, kernel: String) -> String {
    let local = bonjour?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = local.isEmpty ? kernel : "\(local).local"
    return name.lowercased()
  }

  private static var bonjourName: String? {
    #if os(macOS)
      SCDynamicStoreCopyLocalHostName(nil) as String?
    #else
      nil
    #endif
  }

  /// Only when the Bonjour name cannot be read: the hub falls back to it too.
  private static var kernelName: String {
    var bytes = [CChar](repeating: 0, count: 256)
    guard gethostname(&bytes, bytes.count) == 0 else { return "" }
    let units = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: units, as: UTF8.self)
  }
}
