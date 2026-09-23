import Foundation
import Observation
import Tether

/// Copies in flight between this machine and the far side, and the ones that
/// failed. A finished copy leaves the list: it is in the directory now, or
/// open in Quick Look, and a row saying so would be decoration.
@MainActor @Observable
final class Transfers {
  enum Direction: Sendable { case down, up }

  struct Item: Identifiable, Equatable {
    let id = UUID()
    /// Displayable already.
    let name: String
    /// The far side's path: where it comes from, or where it is going.
    let path: String
    let direction: Direction
    let total: UInt64
    var done: UInt64 = 0
    var failure: String?

    var fraction: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }
  }

  private(set) var items: [Item] = []
  /// How to stop each running copy.
  private var cancellers: [UUID: () -> Void] = [:]

  /// How many are still moving bytes. What closing the tab would stop.
  var running: Int { items.count { $0.failure == nil } }

  func item(for path: String) -> Item? { items.first { $0.path == path && $0.failure == nil } }

  /// Copies `entry` to `destination`, returning it once the copy is whole.
  func download(_ entry: FileEntry, to destination: URL, from source: any FileSource)
    async throws -> URL
  {
    try await run(
      Item(name: Names.display(entry.name), path: entry.path, direction: .down, total: entry.size)
    ) { progress in
      _ = try await source.download(entry.path, to: destination.path, progress: progress)
    }
    return destination
  }

  /// Copies `local` to `path` on the far side.
  func upload(_ local: URL, to path: String, replacing: Bool, from source: any FileSource)
    async throws
  {
    let size = (try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    try await run(
      Item(
        name: Names.display(Paths.name(path)), path: path, direction: .up, total: UInt64(size))
    ) { progress in
      _ = try await source.upload(local.path, to: path, replacing: replacing, progress: progress)
    }
  }

  /// Stops a running copy, or forgets a failed one.
  func cancel(_ id: UUID) {
    cancellers[id]?()
    items.removeAll { $0.id == id && $0.failure != nil }
  }

  func cancelAll() {
    cancellers.values.forEach { $0() }
  }

  /// Forgets the failures. Running copies stay.
  func clearFailures() {
    items.removeAll { $0.failure != nil }
  }

  private func run(
    _ item: Item, _ body: @escaping @Sendable (@escaping @Sendable (UInt64) -> Void) async throws -> Void
  ) async throws {
    items.append(item)
    let id = item.id
    let progress: @Sendable (UInt64) -> Void = { [weak self] bytes in
      Task { @MainActor in self?.advance(id, to: bytes) }
    }
    let work = Task<Result<Void, Error>, Never> {
      do {
        try await body(progress)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    cancellers[id] = { work.cancel() }
    let result = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    cancellers[id] = nil
    switch result {
    case .success:
      items.removeAll { $0.id == id }
    case .failure(let error):
      if error is CancellationError || (error as? FileError) == .cancelled {
        items.removeAll { $0.id == id }
      } else if let index = items.firstIndex(where: { $0.id == id }) {
        items[index].failure = describe(error)
      }
      throw error
    }
  }

  private func advance(_ id: UUID, to bytes: UInt64) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].done = max(items[index].done, bytes)
  }
}
