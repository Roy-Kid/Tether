import Foundation

/// The phone input method's document, which is only the word still being chosen.
///
/// A terminal has no local text to edit: the screen belongs to the remote
/// program. While pinyin (or kana, or hangul) is open, that word is the whole
/// document, in UTF-16 because that is the unit `NSRange` counts. Confirming
/// it sends it. Replacing it sends the replacement and not the letters it
/// replaced. Clearing it sends nothing, so the candidate that follows is not
/// preceded by the spelling.
struct PhoneComposition: Equatable {
  private(set) var marked = ""
  /// The input method's caret inside `marked`. Empty when nothing is marked.
  var caret = NSRange(location: 0, length: 0)

  var isEmpty: Bool { marked.isEmpty }
  /// End of the marked word, in UTF-16.
  var end: Int { marked.utf16.count }

  /// Replaces the composition. An empty string abandons it and sends nothing:
  /// the following insert is the candidate.
  mutating func setMarked(_ text: String?, selected: NSRange) {
    marked = text ?? ""
    let limit = end
    let location = min(max(0, selected.location), limit)
    let length = min(max(0, selected.length), limit - location)
    caret = NSRange(location: location, length: length)
  }

  /// The marked word is the character the person confirmed. Empty means a
  /// commit already left through `insert`, and must not be sent again.
  mutating func unmark() -> String? {
    guard !marked.isEmpty else { return nil }
    let text = marked
    clear()
    return text
  }

  /// What was marked is replaced by `text`. Only `text` is sent.
  mutating func insert(_ text: String) -> String? {
    clear()
    return text.isEmpty ? nil : text
  }

  /// Edits the word still being chosen. False means there is nothing marked,
  /// so the caller deletes the cell under the caret instead.
  mutating func deleteBackward() -> Bool {
    guard !marked.isEmpty else { return false }
    marked.removeLast()
    caret = NSRange(location: end, length: 0)
    return true
  }

  private mutating func clear() {
    marked = ""
    caret = NSRange(location: 0, length: 0)
  }
}
