#if os(iOS)
import SwiftUI
import UIKit

extension KeyBinding {
  /// A hardware keyboard's press, the way a Mac's key event is read: the
  /// key's identity for the keys that are not text, its unmodified
  /// character otherwise.
  init?(key: UIKey) {
    var modifiers: KeyModifiers = []
    if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
    if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
    if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
    if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
    if let named = Self.named(key.keyCode) {
      self.init(named, modifiers)
      return
    }
    let characters = key.charactersIgnoringModifiers
    guard !characters.isEmpty else { return nil }
    self.init(characters, modifiers)
  }

  private static func named(_ code: UIKeyboardHIDUsage) -> String? {
    switch code {
    case .keyboardReturnOrEnter, .keypadEnter: "return"
    case .keyboardTab: "tab"
    case .keyboardSpacebar: "space"
    case .keyboardDeleteOrBackspace: "backspace"
    case .keyboardEscape: "escape"
    case .keyboardDeleteForward: "delete"
    case .keyboardHome: "home"
    case .keyboardEnd: "end"
    case .keyboardPageUp: "pageup"
    case .keyboardPageDown: "pagedown"
    case .keyboardLeftArrow: "left"
    case .keyboardRightArrow: "right"
    case .keyboardDownArrow: "down"
    case .keyboardUpArrow: "up"
    default:
      // F1 to F12 are consecutive usages; F13 to F20 are another run.
      if (UIKeyboardHIDUsage.keyboardF1.rawValue...UIKeyboardHIDUsage.keyboardF12.rawValue).contains(code.rawValue) {
        "f\(code.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue + 1)"
      } else if (UIKeyboardHIDUsage.keyboardF13.rawValue...UIKeyboardHIDUsage.keyboardF20.rawValue)
        .contains(code.rawValue)
      {
        "f\(code.rawValue - UIKeyboardHIDUsage.keyboardF13.rawValue + 13)"
      } else {
        nil
      }
    }
  }
}

/// A first responder that takes the next press as a shortcut, on an iPad
/// with a keyboard. Escape alone cancels, as it does on a Mac.
struct KeyBindingRecorder: UIViewRepresentable {
  let record: (KeyBinding?) -> Void
  let cancel: () -> Void

  func makeUIView(context: Context) -> RecorderView { RecorderView() }
  func updateUIView(_ view: RecorderView, context: Context) {
    view.record = record
    view.cancel = cancel
  }

  final class RecorderView: UIView {
    var record: ((KeyBinding?) -> Void)?
    var cancel: (() -> Void)?
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard let key = presses.compactMap(\.key).first else {
        super.pressesBegan(presses, with: event)
        return
      }
      // A modifier on its own is the start of a chord, not a shortcut: a
      // Mac never reports one as a key press, and neither does this.
      let modifierKeys = UIKeyboardHIDUsage.keyboardLeftControl.rawValue...UIKeyboardHIDUsage.keyboardRightGUI.rawValue
      if modifierKeys.contains(key.keyCode.rawValue) { return }
      let binding = KeyBinding(key: key)
      if binding?.key == "escape", binding?.modifiers.isEmpty == true { cancel?() } else { record?(binding) }
    }

    override func resignFirstResponder() -> Bool {
      let cancel = cancel
      DispatchQueue.main.async { cancel?() }
      return super.resignFirstResponder()
    }
  }
}
#endif
