#if os(macOS)
import AppKit
import Testing
import Tether

@testable import TetherUI

@MainActor
@Suite("Input method positioning")
struct InputMethodTests {
  @Test("all Control letters reach the terminal unchanged, including editing and process-control keys")
  func unixNavigation() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let view = KeyCaptureView(frame: .zero)
    window.contentView!.addSubview(view)
    window.makeFirstResponder(view)
    var inputs: [TerminalInput] = []
    view.onInput = { inputs.append($0) }
    for scalar in UInt32(97)...122 {
      let letter = String(UnicodeScalar(scalar)!)
      let character = String(UnicodeScalar(scalar - 96)!)
      let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .control, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: character, charactersIgnoringModifiers: letter,
        isARepeat: false, keyCode: 0))
      inputs.removeAll()
      #expect(view.performKeyEquivalent(with: event))
      #expect(inputs == [.key(.text(letter), KeyModifiers(control: true))])
    }
    let arrows: [(Key, UInt16)] = [(.up, 126), (.down, 125), (.left, 123), (.right, 124)]
    for (key, code) in arrows {
      let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code))
      inputs.removeAll()
      #expect(view.performKeyEquivalent(with: event))
      #expect(inputs == [.key(key)])
    }
  }

  @Test("the terminal does not reserve an application's former Ctrl-Shift-P binding")
  func unboundShortcutReachesTerminal() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let view = KeyCaptureView(frame: .zero)
    window.contentView!.addSubview(view)
    window.makeFirstResponder(view)
    var inputs = 0
    view.onInput = { _ in inputs += 1 }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [.control, .shift], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: "\u{10}", charactersIgnoringModifiers: "P", isARepeat: false, keyCode: 35))
    #expect(view.performKeyEquivalent(with: event))
    #expect(inputs == 1)
  }

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
