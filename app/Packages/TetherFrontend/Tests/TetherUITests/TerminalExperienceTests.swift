import Testing
import Tether
@testable import TetherUI

@Suite("Terminal experience")
struct TerminalExperienceTests {
  @Test func pasteBoundaries() {
    #expect(!TerminalPastePolicy.requiresConfirmation("echo hello", threshold: 4096))
    #expect(!TerminalPastePolicy.requiresConfirmation(String(repeating: "x", count: 4095), threshold: 4096))
    #expect(TerminalPastePolicy.requiresConfirmation(String(repeating: "x", count: 4096), threshold: 4096))
    for text in ["echo hello\n", "echo hello\r", "a\r\nb"] {
      #expect(TerminalPastePolicy.requiresConfirmation(text, threshold: 4096))
    }
    #expect(TerminalPastePolicy.requiresConfirmation("abcd", threshold: 4))
  }

  @Test func selectionPreservesWideAndCombiningText() {
    let style = CellStyle(
      foreground: .named(name: .foreground), background: .named(name: .background),
      underline: .none, underlineColor: nil, bold: false, dim: false, italic: false,
      strikethrough: false, inverse: false, hidden: false)
    let frame = ScreenFrame(
      columns: 6, rows: 2, cursorRow: 0, cursorColumn: 0, cursorShape: .hidden,
      cursorVisible: false, alternateScreen: false, viewportOffset: 0, historyLines: 0,
      title: "", lines: [
        ScreenRow(runs: [StyledRun(text: "a", columns: 1, style: style),
          StyledRun(text: "中", columns: 2, style: style),
          StyledRun(text: "e\u{301}  ", columns: 3, style: style)]),
        ScreenRow(runs: [StyledRun(text: "second", columns: 6, style: style)])])
    #expect(TerminalSelection.text(frame: frame, range: 2...3) == "中e\u{301}")
    #expect(TerminalSelection.text(frame: frame, range: 3...7) == "e\u{301}\nse")
    #expect(TerminalSelection.text(frame: frame, range: 6...11) == "second")
  }

  #if os(macOS)
  @Test func shortcutsValidateAsASet() {
    #expect(TerminalShortcuts.validate(TerminalShortcuts.defaults) == nil)
    #expect(TerminalShortcut(" shift + cmd + c ") == TerminalShortcut("Cmd+Shift+C"))
    for text in ["C", "Shift+C", "Cmd+Cmd+C", "Cmd+", "Cmd++", "Cmd+Unknown"] {
      #expect(TerminalShortcut(text) == nil)
    }
    var duplicate = TerminalShortcuts.defaults
    duplicate["copy"] = "cmd+v"
    #expect(TerminalShortcuts.validate(duplicate) != nil)
    duplicate["copy"] = "Cmd+Q"
    #expect(TerminalShortcuts.validate(duplicate) != nil)
  }
  #endif
}
