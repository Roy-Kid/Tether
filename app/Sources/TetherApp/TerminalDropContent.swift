#if os(macOS)
  import AppKit
  import TetherPluginKit

  /// What a drop on a terminal carries, read from the whole pasteboard.
  ///
  /// A row dragged out of a plugin's list carries its path on its own item,
  /// beside whatever else it is — a file's promise — and the terminal pastes
  /// every path, one a line, in the order they were dragged. Anything else
  /// that is a file, Finder's included, is handed on as files.
  enum TerminalDropContent: Equatable {
    case paste(String)
    case files([URL])

    static let droppedPath = NSPasteboard.PasteboardType(DroppedPath.contentType.identifier)
    static let types: [NSPasteboard.PasteboardType] = [droppedPath, .fileURL]

    static func read(_ board: NSPasteboard) -> Self? {
      let paths = (board.pasteboardItems ?? []).compactMap { item in
        item.data(forType: droppedPath).flatMap(DroppedPath.text(in:))
      }
      if !paths.isEmpty { return .paste(paths.joined(separator: "\n")) }
      let objects = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      let urls = (objects as? [URL]) ?? []
      return urls.isEmpty ? nil : .files(urls)
    }
  }
#endif
