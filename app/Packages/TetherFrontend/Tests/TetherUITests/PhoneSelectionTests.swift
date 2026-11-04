#if os(iOS)
import Testing
import UIKit
import Tether

@testable import TetherUI

@MainActor
@Suite("Phone terminal editing", .serialized)
struct PhoneSelectionTests {
  private func view() -> KeyCaptureView {
    let view = KeyCaptureView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
    view.wantsFocus = true
    view.geometry = CellGeometry(cellWidth: 10, lineHeight: 20, inset: 0, columns: 20, rows: 3)
    return view
  }

  @Test("a caret is always present, and pinyin marks through either entry")
  func caretLetsMarkedTextStart() {
    let view = view()
    #expect(view.selectedTextRange?.isEmpty == true)
    view.setMarkedText("ni", selectedRange: NSRange(location: 1, length: 0))
    #expect(view.composing == "ni")
    #expect(view.offset(from: view.beginningOfDocument, to: view.selectedTextRange!.start) == 1)
    view.setAttributedMarkedText(NSAttributedString(string: "你"), selectedRange: NSRange(location: 1, length: 0))
    #expect(view.composing == "你")
    #expect(PhoneInput.correction(for: "zh-Hans") == .default)
    #expect(PhoneInput.correction(for: "en-US") == .no)
    #expect(PhoneInput.multistage("ja-JP"))
    #expect(!PhoneInput.multistage("en"))
  }

  @Test("composing text stays until a candidate is chosen")
  func composingStaysUntilCommit() {
    let view = view()
    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
    #expect(view.composing == "ni")
    #expect(view.markedTextRange != nil)
    var sent: [TerminalInput] = []
    view.onInput = { sent.append($0) }
    view.deleteBackward()
    #expect(view.composing == "n")
    #expect(sent.isEmpty, "backspace edits the word, not the cell under the caret")
    view.insertText("你")
    #expect(view.composing.isEmpty)
    #expect(sent == [.key(.text("你"))])
    view.unmarkText()
    #expect(sent == [.key(.text("你"))])
  }

  @Test("unmark commits marked letters, and clearing the composition sends nothing")
  func unmarkCommitsMarkedLetters() {
    let view = view()
    var sent: [TerminalInput] = []
    view.onInput = { sent.append($0) }
    view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0))
    view.unmarkText()
    #expect(view.composing.isEmpty)
    #expect(sent == [.key(.text("a"))])
    view.unmarkText()
    #expect(sent.count == 1)
    view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
    view.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
    #expect(view.composing.isEmpty)
    #expect(sent.count == 1)
    #expect(!view.selectionRects(for: view.selectedTextRange!).isEmpty)
  }

  @Test("Copy uses the displayed selection and is unavailable while input is suspended")
  func copySelection() {
    let view = view()
    let selection = GridSelection(anchor: GridPoint(row: 0, column: 1), head: GridPoint(row: 1, column: 3))
    var updates: [SelectionUpdate] = []
    view.onSelection = { updates.append($0) }
    #expect(!view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
    view.selection = selection
    #expect(view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
    view.copy(nil)
    #expect(updates == [.copyExisting(selection)])
    view.wantsFocus = false
    view.copy(nil)
    #expect(updates.count == 1)
    #expect(!view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
  }

  @Test("Paste clears selection and sends a paste event rather than keyboard text")
  func pasteIsPaste() {
    let view = view()
    view.selection = GridSelection(anchor: GridPoint(row: 0, column: 0), head: GridPoint(row: 0, column: 3))
    var cleared = false
    var pasted: String?
    view.onSelection = { if $0 == .clear { cleared = true } }
    view.onInput = { if case .paste(let text) = $0 { pasted = text } }
    view.pasteText("echo hello\n")
    #expect(cleared)
    #expect(view.selection == nil)
    #expect(pasted == "echo hello\n")
    pasted = nil
    view.wantsFocus = false
    view.pasteText("echo hello\n")
    #expect(pasted == nil)
  }
}
#endif
