import Foundation
import Tether

enum TerminalSelection {
  static func text(frame: ScreenFrame, range: ClosedRange<Int>) -> String {
    let columns = Int(frame.columns)
    guard columns > 0, range.lowerBound >= 0 else { return "" }
    var lines: [String] = []
    for row in (range.lowerBound / columns)...(range.upperBound / columns) where row < frame.lines.count {
      var column = row * columns
      var text = ""
      for run in frame.lines[row].runs {
        // The SDK splits runs whenever cell width changes. Count graphemes,
        // not scalars, to keep combining marks attached to their base.
        let characters = Array(run.text)
        let width = characters.isEmpty ? 1 : max(1, Int(run.columns) / characters.count)
        for (index, character) in characters.enumerated() {
          let start = column + index * width
          if start <= range.upperBound && start + width - 1 >= range.lowerBound {
            text.append(character)
          }
        }
        column += Int(run.columns)
      }
      while text.last == " " { text.removeLast() }
      lines.append(text)
    }
    return lines.joined(separator: "\n")
  }
}
