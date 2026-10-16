#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI
import TetherUI

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

  /// The chord with Shift read as a modifier of the key rather than part of
  /// it: ⇧⌘[ as "[" with Shift, not the "{" those keys type. Defaults are
  /// written this way; a chord someone recorded is the typed character, so
  /// that one is tried first. `nil` when the two are the same.
  static func unshifted(_ event: NSEvent) -> KeyBinding? {
    guard let typed = KeyBinding(event: event), typed.modifiers.contains(.shift),
      let base = asciiCharacter(keyCode: event.keyCode) ?? event.characters(byApplyingModifiers: []),
      base.count == 1
    else { return nil }
    let unshifted = KeyBinding(base, typed.modifiers)
    return unshifted == typed || KeyBinding.namedKeys[typed.key] != nil || typed.isFunctionKey ? nil : unshifted
  }

  /// What a key types with no modifiers on the ASCII-capable layout.
  ///
  /// A shortcut is a chord of keys, and macOS reads ⌘ chords from that
  /// layout whatever input method is active: with Pinyin on, the "[" key
  /// types "【", but ⇧⌘[ is still ⇧⌘[. Reading the active input source
  /// instead made the chord depend on what language someone was typing.
  static func asciiCharacter(keyCode: UInt16) -> String? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    var deadKeys: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    let status = layout.withUnsafeBytes { raw -> OSStatus in
      guard let keyboard = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return OSStatus(paramErr)
      }
      return UCKeyTranslate(
        keyboard, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length,
        &characters)
    }
    guard status == noErr, length > 0 else { return nil }
    return String(utf16CodeUnits: characters, count: length)
  }

}

/// Runs before the terminal responder, including for Ctrl and Option combinations.
/// Workspace commands stay in the owning window. Native editing aliases can
/// also be enabled for Settings and the owning window's sheets/popovers.
///
/// `handle` is given the chord, whether it is a repeat, and whether a text
/// field is being edited — when most chords belong to the field (spec §4:
/// ⌘⇧Z there is Redo), and declining hands the key on to it and the menus.
struct WorkspaceKeyBindingMonitor: NSViewRepresentable {
  let enabled: Bool
  var textEditingEnabled = false
  let handle: (_ binding: KeyBinding, _ repeated: Bool, _ editingText: Bool) -> Bool

  func makeNSView(context: Context) -> MonitorView { MonitorView() }
  func updateNSView(_ view: MonitorView, context: Context) {
    view.enabled = enabled
    view.textEditingEnabled = textEditingEnabled
    view.handle = handle
  }
  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

  final class MonitorView: NSView {
    var enabled = false
    var textEditingEnabled = false
    var handle: ((KeyBinding, Bool, Bool) -> Bool)?
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
      guard let window, let target = event.window, target.isKeyWindow,
        owns(target, root: window)
      else { return event }
      if let input = target.firstResponder as? NSTextInputClient, input.hasMarkedText() { return event }
      if PickerShortcuts.handle(event) { return nil }
      if enabled, target === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
        let binding = KeyBinding(event: event) {
        let editing = Self.isEditingText(target.firstResponder)
        for chord in [binding, KeyBinding.unshifted(event)].compactMap({ $0 })
        where handle?(chord, event.isARepeat, editing) == true { return nil }
      }
      return textEditingEnabled ? UnixTextEditing.route(event) : event
    }

    /// A field or text view taking typing. The terminal takes keys too, but
    /// it is not text being edited, and it is not a text view.
    static func isEditingText(_ responder: NSResponder?) -> Bool {
      guard let text = responder as? NSTextView else { return false }
      return text.isEditable || text.isFieldEditor
    }

    private func owns(_ target: NSWindow, root: NSWindow) -> Bool {
      if target === root { return true }
      guard let parent = target.sheetParent ?? target.parent else { return false }
      return owns(parent, root: root)
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
