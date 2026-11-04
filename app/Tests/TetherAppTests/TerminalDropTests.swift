#if os(macOS)
  import AppKit
  import Testing
  import TetherPluginKit

  @testable import TetherApp

  /// What a drop on a terminal reads, from a pasteboard of its own.
  @MainActor
  @Suite("Terminal drops")
  struct TerminalDropTests {
    private func board() -> NSPasteboard {
      NSPasteboard(name: .init("tether-terminal-drop-\(UUID())"))
    }

    private func item(path: String, extra: [NSPasteboard.PasteboardType: Data] = [:]) -> NSPasteboardItem {
      let item = NSPasteboardItem()
      item.setData(DroppedPath.data(for: path), forType: TerminalDropContent.droppedPath)
      for (type, data) in extra { item.setData(data, forType: type) }
      return item
    }

    @Test("rows from a list paste their paths, one a line, in the order dragged")
    func pathsPaste() {
      let board = board()
      defer { board.releaseGlobally() }
      board.clearContents()
      // A file's promise carries its path on the same item, beside data the
      // terminal does not read.
      let promise = item(path: "/home/ada/b.txt", extra: [.init("com.apple.NSFilePromiseItemMetaData"): Data([1])])
      #expect(board.writeObjects([promise, item(path: "/home/ada/runs")]))
      #expect(TerminalDropContent.read(board) == .paste("/home/ada/b.txt\n/home/ada/runs"))
    }

  }
#endif
