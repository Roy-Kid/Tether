import Foundation
import Observation
import Synchronization
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
    switch result {
    case .success:
      settle(id, failure: nil)
    case .failure(let error):
      // A taken name is a question the caller asks, not a failed copy.
      settle(id, failure: Self.isTaken(error) ? nil : Self.failure(of: error))
      throw error
    }
  }

  /// A copy the main actor neither runs nor waits for: a file promise,
  /// written on its own queue while Finder waits. The row appears, moves and
  /// settles in the order the copy reports, whenever the main actor gets to
  /// it; its Stop reaches the copy through the report.
  nonisolated func track(_ entry: FileEntry) -> TransferReport {
    let (events, feed) = AsyncStream.makeStream(of: TransferReport.Event.self)
    let report = TransferReport(feed: feed)
    let name = Names.display(entry.name)
    Task { @MainActor [weak self] in
      let item = Item(name: name, path: entry.path, direction: .down, total: entry.size)
      self?.items.append(item)
      self?.cancellers[item.id] = { report.stop() }
      for await event in events {
        switch event {
        case .advanced(let bytes): self?.advance(item.id, to: bytes)
        case .finished(let failure): self?.settle(item.id, failure: failure)
        }
      }
    }
    return report
  }

  /// A finished copy leaves; a stopped one too. A failure stays, saying why.
  private func settle(_ id: UUID, failure: String?) {
    cancellers[id] = nil
    guard let failure else {
      items.removeAll { $0.id == id }
      return
    }
    if let index = items.firstIndex(where: { $0.id == id }) {
      items[index].failure = failure
    }
  }

  /// What a row says about how a copy ended: nothing when it finished or
  /// was stopped.
  nonisolated static func failure(of error: Error?) -> String? {
    guard let error, !isCancellation(error) else { return nil }
    return describe(error)
  }

  nonisolated static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? FileError) == .cancelled
      || (error as? CocoaError)?.code == .userCancelled
  }

  private nonisolated static func isTaken(_ error: Error) -> Bool {
    if case .exists = error as? FileError { return true }
    return false
  }

  private func advance(_ id: UUID, to bytes: UInt64) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].done = max(items[index].done, bytes)
  }
}

/// What a copy running off the main actor tells its row, in order, and how
/// the row's Stop reaches it.
final class TransferReport: Sendable {
  enum Event: Sendable {
    case advanced(UInt64)
    /// Why it failed; nil when it finished or was stopped.
    case finished(String?)
  }

  private let feed: AsyncStream<Event>.Continuation
  /// How to stop the copy, once it has said; whether Stop came first.
  private let stopping = Mutex<(stop: (@Sendable () -> Void)?, stopped: Bool)>((nil, false))

  fileprivate init(feed: AsyncStream<Event>.Continuation) { self.feed = feed }

  func advance(to bytes: UInt64) { feed.yield(.advanced(bytes)) }

  func finish(_ error: Error?) {
    feed.yield(.finished(Transfers.failure(of: error)))
    feed.finish()
  }

  /// What Stop does. A Stop that arrived before this is honoured now.
  func whenStopped(_ stop: @escaping @Sendable () -> Void) {
    let early = stopping.withLock { state in
      state.stop = stop
      return state.stopped
    }
    if early { stop() }
  }

  func stop() {
    let stop = stopping.withLock { state in
      state.stopped = true
      return state.stop
    }
    stop?()
  }
}
