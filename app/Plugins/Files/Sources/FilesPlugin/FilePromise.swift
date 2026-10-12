#if os(macOS)
  import AppKit
  import Tether
  import TetherPluginKit
  import UniformTypeIdentifiers

  extension NSPasteboard.PasteboardType {
    /// The absolute path a plugin dragged, which the terminal pastes.
    static let droppedPath = NSPasteboard.PasteboardType(DroppedPath.contentType.identifier)
  }

  /// A file row dragged out of the list: a promise of the file.
  ///
  /// The bytes are fetched only once a drop has been accepted and its
  /// destination asks for them — Finder does, after the drag is over — on the
  /// writer's own queue, never the main thread. Nothing else rides on this
  /// item: SwiftUI reads an item that holds a promise as the promise alone,
  /// so the path goes beside it (`DraggedRow.paths`). No string either:
  /// given one, Finder would make a text clipping rather than keep the
  /// promise.
  final class FilePromise: NSFilePromiseProvider {
    /// Held here because the provider's delegate is weak.
    let writer: FilePromiseWriter

    init(_ fetch: FileFetch) {
      writer = FilePromiseWriter(fetch)
      super.init()
      fileType = Self.fileType(for: fetch.entry.name).identifier
      delegate = writer
    }

    /// The type the name says, when that is a kind of data; plain data
    /// otherwise. AppKit refuses a promise of anything else, and a row that
    /// is a file is never a bundle, whatever its name.
    static func fileType(for name: String) -> UTType {
      let suffix = (name as NSString).pathExtension
      guard !suffix.isEmpty, let type = UTType(filenameExtension: suffix),
        type.conforms(to: .data), !type.conforms(to: .directory)
      else { return .data }
      return type
    }
  }

  /// Writes one promised file where the drop asked.
  ///
  /// AppKit asks on `queue`, never the main thread, and this returns at
  /// once: the write runs as a task of its own, shows as a row in the
  /// browser's transfers, and calls the completion exactly once — with nil
  /// when the file is there whole, with the reason when it is not. Nothing in
  /// it waits for the main actor; the row is told, not asked.
  final class FilePromiseWriter: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let fetch: FileFetch

    /// Where AppKit asks for writes. Its default is the main queue.
    static let queue: OperationQueue = {
      let queue = OperationQueue()
      queue.name = "Tether file promises"
      queue.qualityOfService = .userInitiated
      return queue
    }()

    init(_ fetch: FileFetch) { self.fetch = fetch }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String)
      -> String
    {
      Names.local(fetch.entry.name)
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    func filePromiseProvider(
      _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
      completionHandler: @escaping (Error?) -> Void
    ) {
      nonisolated(unsafe) let completion = completionHandler
      write(to: url) { completion($0) }
    }

    /// Starts writing the file at `url`. `completion` hears how it ended,
    /// once; the task is returned so a caller can wait for it.
    @discardableResult
    func write(to url: URL, completion: @escaping @Sendable (Error?) -> Void) -> Task<Void, Never> {
      let fetch = fetch
      let report = fetch.transfers?.track(fetch.entry)
      let progress = Self.published(url, total: fetch.entry.size)
      let work = Task.detached(priority: .userInitiated) {
        var failure: Error?
        do {
          try await fetch.write(to: url) { bytes in
            report?.advance(to: bytes)
            progress.completedUnitCount = Int64(clamping: bytes)
          }
        } catch {
          failure = error
        }
        progress.unpublish()
        report?.finish(failure)
        completion(failure.map(Self.forReceiver))
      }
      report?.whenStopped { work.cancel() }
      progress.cancellationHandler = { work.cancel() }
      return work
    }

    /// Progress on the file being written, for whoever shows such things
    /// over a file — Finder, with a way to stop it.
    private static func published(_ url: URL, total: UInt64) -> Progress {
      let progress = Progress(totalUnitCount: Int64(clamping: total))
      progress.kind = .file
      progress.fileOperationKind = .downloading
      progress.fileURL = url
      progress.isCancellable = true
      progress.publish()
      return progress
    }

    /// A stop is the person's own no, which a receiver takes quietly.
    /// Anything else goes as it is, with the sentence the browser shows.
    static func forReceiver(_ error: Error) -> Error {
      Transfers.isCancellation(error) ? CocoaError(.userCancelled) : error
    }
  }

  /// What a dragged row puts on the board, and where it may go.
  @MainActor
  enum DraggedRow {
    /// A file's promise. Folders have none: their contents are not fetched,
    /// so only the terminal can take them, as a path.
    static func promise(for entry: FileEntry, model: FilesTab) -> FilePromise {
      FilePromise(model.fetch(entry))
    }

    /// Every dragged path, as Copy Path would copy them, on an item of its
    /// own: what the terminal pastes. Finder takes no part of it.
    static func paths(_ entries: [FileEntry]) -> NSPasteboardItem {
      let item = NSPasteboardItem()
      item.setData(DroppedPath.data(for: Names.copiedPaths(entries.map(\.path))), forType: .droppedPath)
      return item
    }

    /// Outside this app a drop can take files and nothing else, so a drag of
    /// folders alone is refused there. Inside, the terminal takes paths.
    static func operations(_ context: NSDraggingContext, carriesFiles: Bool) -> NSDragOperation {
      if context == .outsideApplication { return carriesFiles ? .copy : [] }
      return [.copy, .generic]
    }
  }
#endif
