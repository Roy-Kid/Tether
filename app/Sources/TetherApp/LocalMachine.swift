import Foundation

/// Names this Mac answers to. Nerve's hooks report `gethostname` (`os.hostname()`).
/// `ProcessInfo.hostName` is the Bonjour name (`*.local`), which is a different string
/// on a machine that also has a DNS name. Tab marks compare the two.
enum LocalMachine {
  static var kernelName: String {
    var bytes = [CChar](repeating: 0, count: 256)
    guard gethostname(&bytes, bytes.count) == 0 else {
      return ProcessInfo.processInfo.hostName.lowercased()
    }
    let units = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let name = String(decoding: units, as: UTF8.self).lowercased()
    return name.isEmpty ? ProcessInfo.processInfo.hostName.lowercased() : name
  }

  static var names: Set<String> {
    spellings(kernel: kernelName, bonjour: ProcessInfo.processInfo.hostName)
  }

  static func spellings(kernel: String, bonjour: String) -> Set<String> {
    var set: Set<String> = []
    func add(_ raw: String) {
      let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return }
      set.insert(value)
      if let short = value.split(separator: ".").first, !short.isEmpty {
        set.insert(String(short))
      }
      if value.hasSuffix(".local") {
        set.insert(String(value.dropLast(".local".count)))
      }
    }
    add(kernel)
    add(bonjour)
    return set
  }

  /// Both strings are names of this machine, however they are spelled.
  static func same(_ left: String, _ right: String, names: Set<String>? = nil) -> Bool {
    let a = left.lowercased()
    let b = right.lowercased()
    if a == b && !a.isEmpty { return true }
    let known = names ?? self.names
    return known.contains(a) && known.contains(b)
  }

  /// Host strings that should be tried when matching a tab mark on `host`.
  static func lookupNames(for host: String) -> [String] {
    let key = host.lowercased()
    let known = names
    if known.contains(key) { return Array(known) }
    return [key]
  }
}
