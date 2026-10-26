import Foundation

/// The last snapshot this device was handed, so the next open can dial it
/// again after the system has torn the sockets down.
struct HandoffArchive {
  var file: URL

  init(file: URL? = nil) {
    if let file {
      self.file = file
    } else {
      self.file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Tether/handoff.json")
    }
  }

  func load() -> HandoffSnapshot? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(HandoffSnapshot.self, from: data)
  }

  func save(_ snapshot: HandoffSnapshot) {
    do {
      let directory = file.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let data = try JSONEncoder().encode(snapshot)
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {}
  }

  @discardableResult
  func consume() -> HandoffSnapshot? {
    guard let snapshot = load() else { return nil }
    try? FileManager.default.removeItem(at: file)
    return snapshot
  }
}
