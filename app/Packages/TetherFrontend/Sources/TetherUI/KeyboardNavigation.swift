import SwiftUI
#if os(macOS)
import AppKit
#endif

public enum PickerMovement: Sendable {
  case previous, next, pageUp, pageDown, first, last

  public func offset(pageSize: Int) -> Int {
    switch self {
    case .previous: -1
    case .next: 1
    case .pageUp: -max(1, pageSize)
    case .pageDown: max(1, pageSize)
    case .first, .last: 0
    }
  }
}

public extension View {
  func onPickerSubmit(enabled: Bool = true, _ submit: @escaping () -> Void) -> some View {
    self.onKeyPress(keys: [.return, "m", "j", "M", "J"]) { press in
      guard enabled, !isComposingText else { return .ignored }
      let flags = press.modifiers.intersection([.control, .option, .command, .shift])
      guard press.key == .return ? flags.isEmpty : flags == .control else { return .ignored }
      submit()
      return .handled
    }
  }

  /// Picker navigation keeps Ctrl+B/F with the search field's native text editor.
  func onPickerNavigation(enabled: Bool = true, _ move: @escaping (PickerMovement) -> Void) -> some View {
    self
      .onKeyPress(keys: [.upArrow, .downArrow, .home, .end, .pageUp, .pageDown,
                        "p", "n", "v", "P", "N", "V", "<", ">"]) { press in
        guard enabled, !isComposingText else { return .ignored }
        let flags = press.modifiers.intersection([.control, .option, .command, .shift])
        let movement: PickerMovement
        switch (press.key, flags) {
        case (.upArrow, []): movement = .previous
        case (.downArrow, []): movement = .next
        case (.home, []): movement = .first
        case (.end, []): movement = .last
        case (.pageUp, []): movement = .pageUp
        case (.pageDown, []): movement = .pageDown
        default:
          switch (press.key.character.lowercased(), flags) {
          case ("p", .control): movement = .previous
          case ("n", .control): movement = .next
          case ("v", .control): movement = .pageDown
          case ("v", .option): movement = .pageUp
          case ("<", .option), ("<", [.option, .shift]): movement = .first
          case (">", .option), (">", [.option, .shift]): movement = .last
          default: return .ignored
          }
        }
        move(movement)
        return .handled
      }
  }

  func onPickerCancel(_ cancel: @escaping () -> Void) -> some View {
    self
      .onKeyPress(.escape) {
        guard !isComposingText else { return .ignored }
        cancel()
        return .handled
      }
      .onKeyPress(keys: ["g", "G"]) { press in
        guard !isComposingText, press.modifiers.intersection([.control, .option, .command, .shift]) == .control
        else { return .ignored }
        cancel()
        return .handled
      }
  }
}

@MainActor
private var isComposingText: Bool {
  #if os(macOS)
    let window = NSApp.currentEvent?.window ?? NSApp.keyWindow
    return (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
  #else
    return false
  #endif
}
