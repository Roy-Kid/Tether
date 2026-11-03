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

  @Test("a double tap copies a word on a direct keyboard and not while composing")
  func quickCopyOnADirectKeyboard() {
    #expect(PhoneInput.quickCopy(language: "en-US", composing: false))
    #expect(PhoneInput.quickCopy(language: nil, composing: false))
    #expect(!PhoneInput.quickCopy(language: "zh-Hans", composing: false))
    #expect(!PhoneInput.quickCopy(language: "en-US", composing: true))
    let view = view()
    var updates: [SelectionUpdate] = []
    view.onSelection = { updates.append($0) }
    #expect(view.quickCopy(at: CGPoint(x: 15, y: 10), language: "en-US"))
    #expect(updates == [.copy(.word, GridPoint(row: 0, column: 1), GridPoint(row: 0, column: 1))])
    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
    #expect(!view.quickCopy(at: CGPoint(x: 15, y: 10), language: "en-US"))
    #expect(updates.count == 1)
  }

  @Test("a still press selects ordinary text and leaves a link to the system menu")
  func selectionPressLeavesLinks() {
    let view = view()
    #expect(view.ownsSelectionPress(at: CGPoint(x: 15, y: 10)))
    let link = TerminalLink(
      text: "/tmp/a", kind: .path(path: "/tmp/a", line: nil, column: nil), spans: [])
    view.links = TerminalLinks(find: { _, _ in link }, open: { _ in }, menu: { _ in nil })
    #expect(!view.ownsSelectionPress(at: CGPoint(x: 15, y: 10)))
    view.links = .none
    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
    #expect(!view.ownsSelectionPress(at: CGPoint(x: 15, y: 10)))
    let names = (view.gestureRecognizers ?? []).map { String(describing: type(of: $0)) }
    #expect(names.contains { $0.contains("TouchDuration") }, "\(names)")
  }

  @Test("the long-press menu keeps Close and switching with copy")
  func menuKeepsWorkspaceActions() {
    let items = [
      TerminalMenuItem("Switch Terminal", children: [TerminalMenuItem("Shell") {}]),
      .separator,
      TerminalMenuItem("New Terminal") {},
      .separator,
      TerminalMenuItem("Close Terminal") {},
    ]
    #expect(PhoneMenu.workspaceSections(items).map { $0.map(\.title) } == [
      ["Switch Terminal"], ["New Terminal"], ["Close Terminal"],
    ])
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
    // The software keyboard stays down, and the view can still take the menu.
    #expect(view.canBecomeFirstResponder)
    #expect(view.inputView != nil)
    PhoneKeyboard.noteTapped(phone: true)
    #expect(view.canBecomeFirstResponder)
    #expect(view.inputView == nil)
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
