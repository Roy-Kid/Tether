#if os(macOS)
import AppKit
import SwiftUI

extension KeyBinding {
  init?(event: NSEvent) {
    var modifiers: KeyModifiers = []
    if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
    if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
    if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
    if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
    let named: String?
    switch event.keyCode {
    case 36, 76: named = "return"
    case 48: named = "tab"
    case 49: named = "space"
    case 51: named = "backspace"
    case 53: named = "escape"
    case 117: named = "delete"
    case 115: named = "home"
    case 119: named = "end"
    case 116: named = "pageup"
    case 121: named = "pagedown"
    case 123: named = "left"
    case 124: named = "right"
    case 125: named = "down"
    case 126: named = "up"
    default: named = nil
    }
    if let named { self.init(named, modifiers); return }
    guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
    if let scalar = characters.unicodeScalars.first,
      (NSF1FunctionKey...NSF20FunctionKey).contains(Int(scalar.value)) {
      self.init("f\(Int(scalar.value) - NSF1FunctionKey + 1)", modifiers)
    } else {
      self.init(characters, modifiers)
    }
  }

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
      let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
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

/// Runs before the terminal responder, including for Ctrl and Option combinations.
/// The monitor belongs to one workspace window, never the Settings window or sheets.
struct WorkspaceKeyBindingMonitor: NSViewRepresentable {
  let enabled: Bool
  let handle: (KeyBinding, Bool) -> Bool

  func makeNSView(context: Context) -> MonitorView { MonitorView() }
  func updateNSView(_ view: MonitorView, context: Context) {
    view.enabled = enabled
    view.handle = handle
  }
  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

  final class MonitorView: NSView {
    var enabled = false
    var handle: ((KeyBinding, Bool) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        return self.route(event)
      }
    }

    func route(_ event: NSEvent) -> NSEvent? {
      guard enabled, let window, event.window === window, window.isKeyWindow,
        window.attachedSheet == nil, NSApp.modalWindow == nil,
        let binding = KeyBinding(event: event)
      else { return event }
      if let input = window.firstResponder as? NSTextInputClient, input.hasMarkedText() { return event }
      return handle?(binding, event.isARepeat) == true ? nil : event
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// A first responder captures a shortcut without letting it invoke a menu action.
struct KeyBindingRecorder: NSViewRepresentable {
  let record: (KeyBinding?) -> Void
  let cancel: () -> Void

  func makeNSView(context: Context) -> RecorderView { RecorderView() }
  func updateNSView(_ view: RecorderView, context: Context) {
    view.record = record
    view.cancel = cancel
  }
  static func dismantleNSView(_ view: RecorderView, coordinator: ()) { view.stop() }

  final class RecorderView: NSView {
    var record: ((KeyBinding?) -> Void)?
    var cancel: (() -> Void)?
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard let window else { return }
      window.makeFirstResponder(self)
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.window === self.window, self.window?.firstResponder === self else { return event }
        if !event.isARepeat {
          let binding = KeyBinding(event: event)
          if binding?.key == "escape", binding?.modifiers.isEmpty == true { self.cancel?() }
          else { self.record?(binding) }
        }
        return nil
      }
    }

    override func resignFirstResponder() -> Bool {
      let cancel = cancel
      DispatchQueue.main.async { cancel?() }
      return true
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
#endif
