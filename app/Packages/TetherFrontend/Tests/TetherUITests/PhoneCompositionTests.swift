import Foundation
import Testing

@testable import TetherUI

@Suite("Phone composition")
struct PhoneCompositionTests {
  @Test("unmark sends the marked letters, and a second unmark sends nothing")
  func unmarkCommitsOnce() {
    var composition = PhoneComposition()
    composition.setMarked("a", selected: NSRange(location: 1, length: 0))
    let first = composition.unmark()
    #expect(first == "a")
    #expect(composition.isEmpty)
    let second = composition.unmark()
    #expect(second == nil)
  }

  @Test("a candidate replaces the spelling, and the spelling is not sent")
  func insertReplacesMarked() {
    var composition = PhoneComposition()
    composition.setMarked("nihao", selected: NSRange(location: 5, length: 0))
    let inserted = composition.insert("你好")
    #expect(inserted == "你好")
    #expect(composition.isEmpty)
    let again = composition.unmark()
    #expect(again == nil)
  }

  @Test("clearing the composition sends nothing")
  func emptyMarkSendsNothing() {
    var composition = PhoneComposition()
    composition.setMarked("nihao", selected: NSRange(location: 5, length: 0))
    composition.setMarked(nil, selected: NSRange(location: 0, length: 0))
    #expect(composition.isEmpty)
    let abandoned = composition.unmark()
    #expect(abandoned == nil)
    composition.setMarked("", selected: NSRange(location: 0, length: 0))
    let cleared = composition.unmark()
    #expect(cleared == nil)
  }

  @Test("backspace edits the composition until it is gone")
  func backspaceEditsMarked() {
    var composition = PhoneComposition()
    composition.setMarked("ni", selected: NSRange(location: 2, length: 0))
    let edited = composition.deleteBackward()
    #expect(edited)
    #expect(composition.marked == "n")
    #expect(composition.caret.location == 1)
    let emptied = composition.deleteBackward()
    #expect(emptied)
    #expect(composition.isEmpty)
    let missed = composition.deleteBackward()
    #expect(!missed)
  }
}
