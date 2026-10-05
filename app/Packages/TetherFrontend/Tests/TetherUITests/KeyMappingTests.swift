import Tether
import Testing

@testable import TetherUI

#if os(iOS)
  import UIKit

  /// The phone's key table.
  ///
  /// A table of one-line cases is where a variant gets wired to its
  /// neighbour, and nothing downstream can tell: `Home` and `End` both look
  /// like "a key that did something wrong" once the sequence is on the wire.
  /// So each key is asserted against what it claims to be.
  @Suite("Hardware key mapping")
  struct KeyMappingTests {
    @Test("every named key maps to the key it names")
    func namedKeys() {
      #expect(KeyCaptureView.namedKey(for: .keyboardReturnOrEnter) == .enter)
      #expect(KeyCaptureView.namedKey(for: .keypadEnter) == .enter)
      #expect(KeyCaptureView.namedKey(for: .keyboardTab) == .tab)
      #expect(KeyCaptureView.namedKey(for: .keyboardDeleteOrBackspace) == .backspace)
      #expect(KeyCaptureView.namedKey(for: .keyboardEscape) == .escape)
      #expect(KeyCaptureView.namedKey(for: .keyboardDeleteForward) == .delete)
      #expect(KeyCaptureView.namedKey(for: .keyboardInsert) == .insert)

      // The four that are most easily transposed.
      #expect(KeyCaptureView.namedKey(for: .keyboardUpArrow) == .up)
      #expect(KeyCaptureView.namedKey(for: .keyboardDownArrow) == .down)
      #expect(KeyCaptureView.namedKey(for: .keyboardLeftArrow) == .left)
      #expect(KeyCaptureView.namedKey(for: .keyboardRightArrow) == .right)

      #expect(KeyCaptureView.namedKey(for: .keyboardHome) == .home)
      #expect(KeyCaptureView.namedKey(for: .keyboardEnd) == .end)
      #expect(KeyCaptureView.namedKey(for: .keyboardPageUp) == .pageUp)
      #expect(KeyCaptureView.namedKey(for: .keyboardPageDown) == .pageDown)
    }

    @Test("function keys carry their own number")
    func functionKeys() {
      let table: [(UIKeyboardHIDUsage, UInt8)] = [
        (.keyboardF1, 1), (.keyboardF2, 2), (.keyboardF3, 3), (.keyboardF4, 4),
        (.keyboardF5, 5), (.keyboardF6, 6), (.keyboardF7, 7), (.keyboardF8, 8),
        (.keyboardF9, 9), (.keyboardF10, 10), (.keyboardF11, 11), (.keyboardF12, 12),
      ]
      for (usage, number) in table {
        #expect(KeyCaptureView.namedKey(for: usage) == .function(number))
      }
    }

    /// Letters are not named keys. They arrive as text through `insertText`,
    /// and claiming them here as well would send every character twice.
    @Test("ordinary letters are not claimed as named keys")
    func lettersAreText() {
      #expect(KeyCaptureView.namedKey(for: .keyboardA) == nil)
      #expect(KeyCaptureView.namedKey(for: .keyboardZ) == nil)
      #expect(KeyCaptureView.namedKey(for: .keyboardSpacebar) == nil)
      #expect(KeyCaptureView.namedKey(for: .keyboard1) == nil)
    }

    /// The software keyboard must not rewrite a command, or grow a predictive
    /// bar that changes the terminal's height.
    @Test("the software keyboard does not rewrite what is typed")
    @MainActor
    func keyboardDoesNotRewrite() {
      let view = KeyCaptureView(frame: .zero)
      #expect(view.autocorrectionType == .no)
      #expect(view.spellCheckingType == .no)
      #expect(view.autocapitalizationType == .none)
      #expect(view.smartQuotesType == .no)
      #expect(view.smartDashesType == .no)
      #expect(view.smartInsertDeleteType == .no)
    }
  }
#endif
