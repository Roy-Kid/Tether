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

    @Test("files from Finder are files")
    func finderFiles() throws {
      let board = board()
      defer { board.releaseGlobally() }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID()).txt")
      try Data("x".utf8).write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      board.clearContents()
      #expect(board.writeObjects([url as NSURL]))
      #expect(TerminalDropContent.read(board) == .files([url]))
    }

    @Test("anything else is not taken")
    func nothing() {
      let board = board()
      defer { board.releaseGlobally() }
      board.clearContents()
      board.setString("just text", forType: .string)
      #expect(TerminalDropContent.read(board) == nil)
    }
  }
#endif
