import Foundation
import Testing

@testable import TetherUI

@Suite("Phone composition")
struct PhoneCompositionTests {

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
