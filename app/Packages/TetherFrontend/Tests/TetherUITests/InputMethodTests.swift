#if os(macOS)
import AppKit
import Testing

@testable import TetherUI

@MainActor
@Suite("Input method positioning")
struct InputMethodTests {
  @Test("candidate anchor follows the caret inside an offset terminal pane")
  func followsCaret() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 200, width: 800, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let view = KeyCaptureView(frame: NSRect(x: 40, y: 60, width: 640, height: 400))
    window.contentView!.addSubview(view)
    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))

    view.cursorRect = NSRect(x: 88, y: 40, width: 8, height: 16)
    let first = view.firstRect(forCharacterRange: NSRange(location: 0, length: 2), actualRange: nil)
    #expect(first == NSRect(x: 228, y: 604, width: 8, height: 16))

    // A new row moves the candidate anchor down; changing font metrics also
    // changes its size. Neither position is relative to the window's corner.
    view.cursorRect = NSRect(x: 8, y: 80, width: 10, height: 20)
    let next = view.firstRect(forCharacterRange: NSRange(location: 0, length: 2), actualRange: nil)
    #expect(next == NSRect(x: 148, y: 560, width: 10, height: 20))

    view.setFrameSize(NSSize(width: 640, height: 500))
    let resized = view.firstRect(forCharacterRange: NSRange(location: 0, length: 2), actualRange: nil)
    #expect(resized.origin.y == next.origin.y + 100)
  }
}
#endif
