#if os(iOS)

  import SwiftUI
  import Tether
  import UIKit

  /// The same job as the AppKit capture, against a different set of facts.
  ///
  /// A phone has two keyboards and they arrive by different routes. The
  /// software one comes through `UIKeyInput` as text and a backspace, already
  /// composed by whatever input method is on screen. A hardware one comes
  /// through `pressesBegan` as a `UIKey`, which is where arrows, Escape and
  /// control chords live — none of which `UIKeyInput` can express.
  ///
  /// Reading `UIKey.keyCode` rather than a virtual keycode table is the one
  /// place this implementation is plainly better than the Mac's: the HID
  /// usage is the key's identity, so `.keyboardUpArrow` is the arrow on every
  /// layout rather than the number 126 being the arrow on this one.
  struct PhoneKeyCapture: UIViewRepresentable {
    let onInput: (TerminalInput) -> Void
    var active = true
    var onFocus: () -> Void = {}

    func makeUIView(context: Context) -> KeyCaptureView {
      let view = KeyCaptureView()
      view.onInput = onInput
      view.onFocus = onFocus
      view.wantsFocus = active
      return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
      view.onInput = onInput
      view.onFocus = onFocus
      view.wantsFocus = active
      if active && !view.isFirstResponder {
        view.becomeFirstResponder()
      } else if !active && view.isFirstResponder {
        view.resignFirstResponder()
      }
    }
  }

  final class KeyCaptureView: UIView, UIKeyInput {
    var wantsFocus = false
    var onFocus: (() -> Void)?
    var onInput: ((TerminalInput) -> Void)?

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = true
      addGestureRecognizer(
        UITapGestureRecognizer(target: self, action: #selector(takeFocus)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if wantsFocus { becomeFirstResponder() }
    }

    @objc private func takeFocus() {
      becomeFirstResponder()
      onFocus?()
    }

    // MARK: - The software keyboard

    /// Always true. A terminal's content is the remote screen, not this
    /// view's, so "has text" cannot be answered from here — and answering
    /// `false` makes the keyboard suppress its delete key.
    var hasText: Bool { true }

    /// Already composed: an input method resolves marked text before it
    /// reaches this, which is why there is no `setMarkedText` dance here as
    /// there is on the Mac.
    func insertText(_ text: String) {
      // The return key arrives as a newline rather than as a key press, and a
      // terminal wants the carriage return its line editor is waiting for.
      if text == "\n" {
        onInput?(.key(.enter))
        return
      }
      guard !text.isEmpty else { return }
      onInput?(.key(.text(text)))
    }

    func deleteBackward() {
      onInput?(.key(.backspace))
    }

    // MARK: - A hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      var handled = false

      for press in presses {
        guard let key = press.key else { continue }
        // Command chords belong to the system: ⌘V and the rest must keep
        // working, and a terminal has nothing to send for them.
        guard !key.modifierFlags.contains(.command) else { continue }
        guard let input = Self.input(for: key) else { continue }
        onInput?(input)
        handled = true
      }

      // Unhandled presses go on down the chain rather than being swallowed,
      // so the system keeps its own shortcuts.
      if !handled { super.pressesBegan(presses, with: event) }
    }

    static func input(for key: UIKey) -> TerminalInput? {
      let modifiers = KeyModifiers(
        shift: key.modifierFlags.contains(.shift),
        alt: key.modifierFlags.contains(.alternate),
        control: key.modifierFlags.contains(.control))

      if let named = namedKey(for: key.keyCode) {
        return .key(named, modifiers)
      }

      // Plain text with no chord is already on its way through `insertText`;
      // sending it here as well would double every character typed on a
      // hardware keyboard.
      guard modifiers.control || modifiers.alt else { return nil }

      // The base letter, not what the modifier produced: the engine applies
      // the chord itself, against the modes the remote program set.
      let base = key.charactersIgnoringModifiers
      guard !base.isEmpty else { return nil }
      return .key(.text(base), modifiers)
    }

    /// The keys that are not text.
    ///
    /// A HID usage is the key's identity, so this table says what it means
    /// rather than where it sits on one particular keyboard.
    /// Internal rather than private so the table can be checked from a test.
    /// It is exactly the kind of code that fails silently: nothing downstream
    /// can tell `Home` from `End` once the wrong one has been chosen.
    static func namedKey(for code: UIKeyboardHIDUsage) -> Key? {
      switch code {
      case .keyboardReturnOrEnter, .keypadEnter: .enter
      case .keyboardTab: .tab
      case .keyboardDeleteOrBackspace: .backspace
      case .keyboardEscape: .escape
      case .keyboardDeleteForward: .delete
      case .keyboardInsert: .insert
      case .keyboardUpArrow: .up
      case .keyboardDownArrow: .down
      case .keyboardLeftArrow: .left
      case .keyboardRightArrow: .right
      case .keyboardHome: .home
      case .keyboardEnd: .end
      case .keyboardPageUp: .pageUp
      case .keyboardPageDown: .pageDown
      case .keyboardF1: .function(1)
      case .keyboardF2: .function(2)
      case .keyboardF3: .function(3)
      case .keyboardF4: .function(4)
      case .keyboardF5: .function(5)
      case .keyboardF6: .function(6)
      case .keyboardF7: .function(7)
      case .keyboardF8: .function(8)
      case .keyboardF9: .function(9)
      case .keyboardF10: .function(10)
      case .keyboardF11: .function(11)
      case .keyboardF12: .function(12)
      default: nil
      }
    }
  }

#endif
