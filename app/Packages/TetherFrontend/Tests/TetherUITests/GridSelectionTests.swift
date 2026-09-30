import CoreGraphics
import Testing
import Tether

@testable import TetherUI

@Suite("selecting text")
struct GridSelectionTests {
  @Test("a drag copies the cells it covers, in either direction")
  func characterRange() throws {
    let frame = screen([row("hello")], columns: 5)
    let forward = try #require(GridText.selection(.character, from: point(0, 1), to: point(0, 3), in: frame))
    let backward = try #require(GridText.selection(.character, from: point(0, 3), to: point(0, 1), in: frame))
    #expect(GridText.string(in: frame, selection: forward) == "ell")
    #expect(GridText.string(in: frame, selection: backward) == "ell")
  }

  @Test("a drag across two rows keeps the line break and the rest of each line")
  func acrossRows() throws {
    let frame = screen([row("abc"), row("def")], columns: 3)
    let selection = try #require(
      GridText.selection(.character, from: point(0, 1), to: point(1, 1), in: frame))
    #expect(GridText.string(in: frame, selection: selection) == "bc\nde")
    #expect(
      GridText.spans(selection, in: frame) == [
        LinkSpan(row: 0, start: 1, end: 3),
        LinkSpan(row: 1, start: 0, end: 2),
      ])
  }

  @Test("a wide character is copied and highlighted whole when any column is covered")
  func wideCharacters() throws {
    let frame = screen([row("中文", columns: 4)], columns: 4)
    let both = try #require(GridText.selection(.character, from: point(0, 1), to: point(0, 2), in: frame))
    #expect(GridText.string(in: frame, selection: both) == "中文")
    #expect(GridText.spans(both, in: frame) == [LinkSpan(row: 0, start: 0, end: 4)])

    let first = try #require(GridText.selection(.character, from: point(0, 1), to: point(0, 1), in: frame))
    #expect(GridText.string(in: frame, selection: first) == "中")
    #expect(GridText.spans(first, in: frame) == [LinkSpan(row: 0, start: 0, end: 2)])
  }

  @Test("a hidden run copies blanks, never the characters")
  func hiddenIsBlank() throws {
    let frame = screen(
      [
        ScreenRow(runs: [
          run("ab"), run("secret", hidden: true), run("cd"),
        ])
      ], columns: 10)
    let selection = try #require(
      GridText.selection(.character, from: point(0, 0), to: point(0, 9), in: frame))
    let text = GridText.string(in: frame, selection: selection)
    #expect(text == "ab      cd")
    #expect(!text.contains("secret"))
  }

  @Test("trailing spaces are dropped and leading ones stay")
  func trimsTrailing() throws {
    let frame = screen([row("ab  ")], columns: 4)
    let selection = try #require(
      GridText.selection(.character, from: point(0, 0), to: point(0, 3), in: frame))
    #expect(GridText.string(in: frame, selection: selection) == "ab")
  }

  @Test("a double click takes the word, and whitespace is not a word")
  func words() throws {
    let frame = screen([row("foo bar")], columns: 7)
    let word = try #require(GridText.selection(.word, from: point(0, 1), to: point(0, 1), in: frame))
    #expect(GridText.string(in: frame, selection: word) == "foo")
    #expect(GridText.selection(.word, from: point(0, 3), to: point(0, 3), in: frame) == nil)

    let intoSpace = try #require(
      GridText.selection(.word, from: point(0, 0), to: point(0, 3), in: frame))
    #expect(GridText.string(in: frame, selection: intoSpace) == "foo")
  }

  @Test("a triple click takes the line up to its last character")
  func lines() throws {
    let frame = screen([row("hello   ")], columns: 8)
    let line = try #require(GridText.selection(.line, from: point(0, 4), to: point(0, 4), in: frame))
    #expect(GridText.string(in: frame, selection: line) == "hello")
  }

  @Test("the highlight is the same rectangle a link would draw")
  func highlightMatchesTheGrid() throws {
    let geometry = CellGeometry(cellWidth: 8, lineHeight: 16, inset: 8, columns: 5, rows: 1)
    let frame = screen([row("hello")], columns: 5)
    let selection = try #require(
      GridText.selection(.character, from: point(0, 1), to: point(0, 3), in: frame))
    let span = try #require(GridText.spans(selection, in: frame).first)
    #expect(geometry.rect(for: span) == CGRect(x: 16, y: 8, width: 24, height: 16))
  }

  @Test("two equal cells are not each before the other")
  func equalPoints() {
    let cell = GridPoint(row: 1, column: 2)
    #expect(!cell.isBefore(cell))
    let selection = GridSelection(anchor: cell, head: cell)
    #expect(selection.start == cell)
    #expect(selection.end == cell)
  }

  private func point(_ row: Int, _ column: Int) -> GridPoint {
    GridPoint(row: row, column: column)
  }

  private func cellStyle(hidden: Bool = false) -> CellStyle {
    CellStyle(
      foreground: .named(name: .foreground),
      background: .named(name: .background),
      underline: .none, underlineColor: nil, bold: false, dim: false,
      italic: false, strikethrough: false, inverse: false, hidden: hidden)
  }

  private func run(_ text: String, columns: UInt32? = nil, hidden: Bool = false) -> StyledRun {
    StyledRun(text: text, columns: columns ?? UInt32(text.count), style: cellStyle(hidden: hidden))
  }

  private func row(_ text: String, columns: UInt32? = nil, hidden: Bool = false) -> ScreenRow {
    ScreenRow(runs: [run(text, columns: columns, hidden: hidden)])
  }

  private func screen(_ lines: [ScreenRow], columns: UInt32) -> ScreenFrame {
    ScreenFrame(
      columns: columns, rows: UInt32(lines.count), cursorRow: 0, cursorColumn: 0,
      cursorShape: .hidden, cursorVisible: false, alternateScreen: false,
      viewportOffset: 0, historyLines: 0, title: "", lines: lines)
  }
}
