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
  }

  @Test("a vertical drag scrolls when a program has taken the mouse")
  func verticalDragScrolls() {
    #expect(PhoneDrag.kind(touches: 1, mouse: .off, selecting: false, translation: .zero) == .scroll)
    #expect(PhoneDrag.kind(touches: 2, mouse: .drag, selecting: false, translation: .zero) == .scroll)
    #expect(
      PhoneDrag.kind(touches: 1, mouse: .drag, selecting: false, translation: CGPoint(x: 0, y: 20))
        == .scroll)
    #expect(
      PhoneDrag.kind(touches: 1, mouse: .drag, selecting: false, translation: CGPoint(x: 30, y: 4))
        == .pointer)
    #expect(
      PhoneDrag.kind(touches: 1, mouse: .off, selecting: true, translation: CGPoint(x: 0, y: 20))
        == .selection)
  }

  @Test("ordinary terminal text has an editing menu without a link")
  func menuWithoutLink() {
    let view = view()
    let interaction = UIContextMenuInteraction(delegate: view)
    #expect(view.contextMenuInteraction(interaction, configurationForMenuAtLocation: CGPoint(x: 15, y: 10)) != nil)
    view.wantsFocus = false
    #expect(view.contextMenuInteraction(interaction, configurationForMenuAtLocation: CGPoint(x: 15, y: 10)) == nil)
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

  @Test("the software keyboard stays down until the terminal is tapped, and after leaving the app")
  func keyboardStaysDownUntilTap() {
    let saved = PhoneKeyboard.staysDown
    defer { PhoneKeyboard.staysDown = saved }
    PhoneKeyboard.staysDown = true
    #expect(!PhoneKeyboard.allowsAutomaticFocus(phone: true))
    #expect(PhoneKeyboard.allowsAutomaticFocus(phone: false))
    PhoneKeyboard.noteTapped(phone: true)
    #expect(PhoneKeyboard.allowsAutomaticFocus(phone: true))
    PhoneKeyboard.noteLeftForeground(phone: true)
    #expect(!PhoneKeyboard.allowsAutomaticFocus(phone: true))
    PhoneKeyboard.noteTapped(phone: false)
    #expect(!PhoneKeyboard.allowsAutomaticFocus(phone: true))
    PhoneKeyboard.noteLeftForeground(phone: false)
    #expect(!PhoneKeyboard.allowsAutomaticFocus(phone: true))
    let view = view()
    #expect(!view.canBecomeFirstResponder)
    PhoneKeyboard.noteTapped(phone: true)
    #expect(view.canBecomeFirstResponder)
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
