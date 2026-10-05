import SwiftUI
import Tether

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// How a drag chooses text. A character drag is the cells under the pointer.
/// A word or a line drag, from a double or triple click, grows by that unit.
enum SelectionKind: Equatable {
  case character
  case word
  case line
}

/// One cell, in the frame's own rows and columns.
struct GridPoint: Equatable, Hashable, Sendable {
  var row: Int
  var column: Int

  /// Reading order, strictly: an earlier row, then an earlier column.
  ///
  /// Not `<=`. `min` and `max` trap when the comparison says two equal
  /// points are each before the other.
  func isBefore(_ other: GridPoint) -> Bool {
    row < other.row || (row == other.row && column < other.column)
  }
}

/// The cells a drag covers. `anchor` is where it began and `head` is where
/// it is now, in either order.
struct GridSelection: Equatable, Sendable {
  var anchor: GridPoint
  var head: GridPoint

  var start: GridPoint { head.isBefore(anchor) ? head : anchor }
  var end: GridPoint { head.isBefore(anchor) ? anchor : head }
}

/// What the capture view reports. The surface owns the text, because a word
/// is a fact about the frame and the view under the pointer does not have it.
enum SelectionUpdate: Equatable {
  /// The drag moved. Highlight, do not touch the clipboard yet.
  case highlight(SelectionKind, GridPoint, GridPoint)
  /// The drag ended on a real selection. Highlight it and copy it.
  case copy(SelectionKind, GridPoint, GridPoint)
  /// ⌘C. The selection is the one already on screen.
  case copyExisting(GridSelection)
  case clear
}

/// The text and the rectangles of a selection.
///
/// A run is graphemes of one width, so a column has to be walked rather than
/// counted in scalars: the right half of a wide character is the character,
/// and a hidden cell is a password, which must not reach the clipboard.
enum GridText {
  static func selection(
    _ kind: SelectionKind, from: GridPoint, to: GridPoint, in frame: ScreenFrame
  ) -> GridSelection? {
    switch kind {
    case .character:
      GridSelection(anchor: from, head: to)
    case .word:
      words(in: frame, from: from, to: to)
    case .line:
      lines(in: frame, from: from, to: to)
    }
  }

  static func string(in frame: ScreenFrame, selection: GridSelection) -> String {
    let columns = Int(frame.columns)
    guard columns > 0 else { return "" }
    let start = selection.start
    let end = selection.end
    guard start.row <= end.row else { return "" }
    var lines: [String] = []
    for row in start.row...end.row {
      guard frame.lines.indices.contains(row) else { continue }
      let from = row == start.row ? start.column : 0
      let through = row == end.row ? end.column : columns - 1
      lines.append(trimmingTrailing(slice(frame.lines[row], from: from, through: through)))
    }
    return lines.joined(separator: "\n")
  }

  /// One rectangle per row, in the same spans a link uses: `end` is one past
  /// the last column. A wide character is covered whole when any of its
  /// columns is, so the highlight matches the text that is copied.
  static func spans(_ selection: GridSelection, in frame: ScreenFrame) -> [LinkSpan] {
    let columns = Int(frame.columns)
    let rows = Int(frame.rows)
    guard columns > 0, rows > 0 else { return [] }
    let start = selection.start
    let end = selection.end
    guard start.row <= end.row else { return [] }
    var result: [LinkSpan] = []
    for row in start.row...end.row where row >= 0 && row < rows {
      let from = row == start.row ? start.column : 0
      let through = row == end.row ? end.column : columns - 1
      var loColumn = from
      var hiColumn = through
      if frame.lines.indices.contains(row) {
        for cluster in clusters(in: frame.lines[row]) {
          let clusterEnd = cluster.column + cluster.width - 1
          if clusterEnd < from || cluster.column > through { continue }
          loColumn = min(loColumn, cluster.column)
          hiColumn = max(hiColumn, clusterEnd)
        }
      }
      let lo = min(max(loColumn, 0), columns)
      let hi = min(max(hiColumn + 1, lo), columns)
      guard hi > lo, row <= Int(UInt16.max), lo <= Int(UInt16.max), hi <= Int(UInt16.max) else {
        continue
      }
      result.append(LinkSpan(row: UInt16(row), start: UInt16(lo), end: UInt16(hi)))
    }
    return result
  }

  private struct Span {
    var start: GridPoint
    var end: GridPoint
  }

  private static func words(in frame: ScreenFrame, from: GridPoint, to: GridPoint) -> GridSelection? {
    let start = wordSpan(in: frame, at: from)
    let end = wordSpan(in: frame, at: to)
    if start == nil, end == nil, from == to { return nil }
    let covered = union(start ?? Span(start: from, end: from), end ?? Span(start: to, end: to))
    return GridSelection(anchor: covered.start, head: covered.end)
  }

  private static func lines(in frame: ScreenFrame, from: GridPoint, to: GridPoint) -> GridSelection? {
    guard !frame.lines.isEmpty else { return nil }
    let last = frame.lines.count - 1
    let top = min(max(min(from.row, to.row), 0), last)
    let bottom = min(max(max(from.row, to.row), 0), last)
    let endColumn = lastContentColumn(frame.lines[bottom]) ?? 0
    return GridSelection(anchor: GridPoint(row: top, column: 0), head: GridPoint(row: bottom, column: endColumn))
  }

  private static func wordSpan(in frame: ScreenFrame, at point: GridPoint) -> Span? {
    guard frame.lines.indices.contains(point.row) else { return nil }
    let glyphs = clusters(in: frame.lines[point.row])
    guard
      let index = glyphs.firstIndex(where: {
        $0.column <= point.column && point.column < $0.column + $0.width
      }),
      isWord(glyphs[index])
    else { return nil }
    var lower = index
    var upper = index
    while lower > 0, isWord(glyphs[lower - 1]) { lower -= 1 }
    while upper + 1 < glyphs.count, isWord(glyphs[upper + 1]) { upper += 1 }
    return Span(
      start: GridPoint(row: point.row, column: glyphs[lower].column),
      end: GridPoint(row: point.row, column: glyphs[upper].column + glyphs[upper].width - 1))
  }

  private static func union(_ a: Span, _ b: Span) -> Span {
    let points = [a.start, a.end, b.start, b.end]
    let start = points.min { $0.isBefore($1) } ?? a.start
    let end = points.max { $0.isBefore($1) } ?? a.end
    return Span(start: start, end: end)
  }

  private static func lastContentColumn(_ row: ScreenRow) -> Int? {
    guard let last = clusters(in: row).last(where: isWord) else { return nil }
    return last.column + last.width - 1
  }

  private struct Cluster {
    var text: String
    var column: Int
    var width: Int
  }

  private static func clusters(in row: ScreenRow) -> [Cluster] {
    var column = 0
    var result: [Cluster] = []
    for run in row.runs {
      let glyphs = Array(run.text)
      guard !glyphs.isEmpty, run.columns > 0 else { continue }
      let base = Int(run.columns) / glyphs.count
      let extra = Int(run.columns) % glyphs.count
      for (index, glyph) in glyphs.enumerated() {
        let width = max(base + (index == glyphs.count - 1 ? extra : 0), 1)
        // A hidden cell still occupies its column. The character itself is a
        // secret — a password the program asked not to be shown — so the
        // copy gets a blank of the same width's place, never the character.
        result.append(Cluster(
          text: run.style.hidden ? " " : String(glyph), column: column, width: width))
        column += width
      }
    }
    return result
  }

  private static func isWord(_ cluster: Cluster) -> Bool {
    cluster.text.contains { !$0.isWhitespace }
  }

  private static func slice(_ row: ScreenRow, from: Int, through: Int) -> String {
    guard through >= from else { return "" }
    var text = ""
    for cluster in clusters(in: row) {
      let clusterEnd = cluster.column + cluster.width - 1
      if clusterEnd < from || cluster.column > through { continue }
      text += cluster.text
    }
    return text
  }

  private static func trimmingTrailing(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex {
      let previous = text.index(before: end)
      if text[previous].isWhitespace { end = previous } else { break }
    }
    return String(text[..<end])
  }
}

/// Puts text on the clipboard. An empty selection writes nothing, so a click
/// does not throw away whatever the person copied before.
enum Clipboard {
  @MainActor
  static func write(_ text: String) {
    guard !text.isEmpty else { return }
    #if os(macOS)
      let board = NSPasteboard.general
      board.clearContents()
      board.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }
}

/// The selection, over the glyphs. It does not take the click: the capture
/// view is the thing under the pointer.
struct SelectionHighlight: View {
  var selection: GridSelection?
  var frame: ScreenFrame
  var geometry: CellGeometry

  var body: some View {
    Canvas { context, _ in
      guard let selection else { return }
      let color = Color.accentColor.opacity(UIStyle.textSelectionOpacity)
      for span in GridText.spans(selection, in: frame) {
        context.fill(Path(geometry.rect(for: span)), with: .color(color))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
