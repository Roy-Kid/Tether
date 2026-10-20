import SwiftUI

extension KeyBinding {
  var keyboardShortcut: KeyboardShortcut? {
    let special: [String: KeyEquivalent] = [
      "left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow,
      "return": .return, "tab": .tab, "space": .space, "escape": .escape,
      "backspace": .delete, "delete": .deleteForward, "home": .home, "end": .end,
      "pageup": .pageUp, "pagedown": .pageDown,
    ]
    let equivalent: KeyEquivalent
    if let value = special[key] { equivalent = value }
    else if isFunctionKey, let number = Int(key.dropFirst()),
      let scalar = UnicodeScalar(0xF704 + number - 1) {
      equivalent = KeyEquivalent(Character(scalar))
    } else if key.count == 1, let character = key.first { equivalent = KeyEquivalent(character) }
    else { return nil }
    var flags: EventModifiers = []
    if modifiers.contains(.control) { flags.insert(.control) }
    if modifiers.contains(.option) { flags.insert(.option) }
    if modifiers.contains(.shift) { flags.insert(.shift) }
    if modifiers.contains(.command) { flags.insert(.command) }
    return KeyboardShortcut(equivalent, modifiers: flags)
  }
}

private struct WorkspaceShortcutsKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
  var workspaceShortcutsEnabled: Bool? {
    get { self[WorkspaceShortcutsKey.self] }
    set { self[WorkspaceShortcutsKey.self] = newValue }
  }
}
