#if os(macOS)
import AppKit

/// Adds the missing Readline-style aliases to native editors. AppKit still
/// owns selection, Unicode boundaries, undo and its kill/yank buffer.
@MainActor
enum UnixTextEditing {
  static func route(_ event: NSEvent) -> NSEvent? {
    guard let editor = event.window?.firstResponder as? NSTextView,
      editor.isEditable, !editor.hasMarkedText(), let binding = KeyBinding(event: event)
    else { return event }

    switch (binding.key, binding.modifiers) {
    case ("b", .option): editor.moveWordBackward(nil)
    case ("f", .option): editor.moveWordForward(nil)
    case ("b", [.option, .shift]): editor.moveWordBackwardAndModifySelection(nil)
    case ("f", [.option, .shift]): editor.moveWordForwardAndModifySelection(nil)
    case ("d", .option): editor.deleteWordForward(nil)
    case ("w", .control): editor.deleteWordBackward(nil)
    case ("u", .control): editor.deleteToBeginningOfParagraph(nil)
    case ("_", .control), ("_", [.control, .shift]):
      if editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
    case ("g", .control):
      // Re-enter ordinary Escape handling, including SwiftUI onExitCommand
      // and the Cancel button of a sheet, instead of swallowing the cancel.
      return replacing(event, characters: "\u{1b}", code: 53)
    case ("m", .control), ("j", .control):
      return replacing(event, characters: "\r", code: 36)
    case ("i", .control):
      return replacing(event, characters: "\t", code: 48)
    default: return event
    }
    return nil
  }

  private static func replacing(_ event: NSEvent, characters: String, code: UInt16) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
      modifierFlags: [], timestamp: event.timestamp, windowNumber: event.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: event.isARepeat, keyCode: code) ?? event
  }
}
#endif
