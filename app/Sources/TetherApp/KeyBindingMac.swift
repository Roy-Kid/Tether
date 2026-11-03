#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI
import TetherPluginKit
import TetherUI

extension KeyBinding {
  private static let keyNamesByCode: [UInt16: String] = [
    36: "return", 76: "return", 48: "tab", 49: "space", 51: "backspace", 53: "escape",
    117: "delete", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    123: "left", 124: "right", 125: "down", 126: "up",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7",
    100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13",
    107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
  ]

  init?(event: NSEvent) {
    var modifiers: KeyModifiers = []
    if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
    if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
    if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
    if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
    if let named = Self.keyNamesByCode[event.keyCode] { self.init(named, modifiers); return }
    guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
    if let scalar = characters.unicodeScalars.first,
      (NSF1FunctionKey...NSF20FunctionKey).contains(Int(scalar.value)) {
      self.init("f\(Int(scalar.value) - NSF1FunctionKey + 1)", modifiers)
    } else {
      self.init(characters, modifiers)
    }
  }

  /// Carbon registration uses the same ASCII-capable layout as local shortcuts.
  var carbonKeyCode: UInt16? {
    if let code = Self.keyNamesByCode.filter({ $0.value == key }).keys.min() { return code }
    return (UInt16(0)..<128).first {
      Self.asciiCharacter(keyCode: $0)?.lowercased() == key
        || (modifiers.contains(.shift)
          && Self.asciiCharacter(keyCode: $0, modifiers: UInt32(shiftKey >> 8))?.lowercased() == key)
    }
  }

  var carbonModifiers: UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.control) { result |= UInt32(controlKey) }
    if modifiers.contains(.option) { result |= UInt32(optionKey) }
    if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
    if modifiers.contains(.command) { result |= UInt32(cmdKey) }
    return result
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
  static func asciiCharacter(keyCode: UInt16, modifiers: UInt32 = 0) -> String? {
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
        keyboard, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
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

/// SwiftUI stores ⇧⌘H as `"h"` plus Shift. AppKit matches that chord only
/// when the letter is uppercase and Shift is not in the mask, so the menu
/// never fires it while the terminal is first responder.
///
/// Each key is rewritten before the menu looks. While a text field is
/// focused, only the palette and the closes stay in that form; every other
/// chord is put back. Redo is never rewritten, so ⇧⌘Z there stays Redo.
enum MenuKeyEquivalents {
  private static let systemActions: Set<String> = [
    "undo:", "redo:", "cut:", "copy:", "paste:", "pasteAsPlainText:", "selectAll:",
    "hide:", "hideOtherApplications:", "terminate:", "performMiniaturize:",
    "performClose:", "performZoom:",
  ]

  static func install(_ handle: @escaping (NSEvent) -> NSEvent?) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handle(event)
    }
  }

  /// Runs a workspace chord from the app monitor. The panel never delivers
  /// that chord to the menu bar, and the view monitor is not the only copy
  /// of these windows. A plugin command is left for the view monitor, which
  /// knows the items the window is offering.
  @MainActor
  static func dispatch(_ event: NSEvent, tabs: TabSet, registry: PluginRegistry) -> NSEvent? {
    guard tabs.menuShortcuts == true,
      let window = event.window, window is WorkspaceWindow, window.isKeyWindow,
      window.attachedSheet == nil, NSApp.modalWindow == nil,
      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
      let binding = KeyBinding(event: event)
    else { return event }
    let editing = WorkspaceKeyBindingMonitor.MonitorView.isEditingText(window.firstResponder)
    let definitions = KeyBindingCatalog.commands(registry: registry, tabs: tabs)
    for chord in [binding, KeyBinding.unshifted(event)].compactMap({ $0 }) {
      guard let id = tabs.keyBindings.command(for: chord, in: definitions, offered: tabs.offeredCommandIDs)
      else { continue }
      guard let action = WorkspaceAction(rawValue: id) else { return event }
      guard !editing || WorkspaceAction.answersWhileEditingText(id) else { return event }
      if !event.isARepeat { tabs.perform(action) }
      return nil
    }
    return event
  }

  static func normalize(
    _ menu: NSMenu, commands: [KeyBindingCommand], editingText: Bool,
    bindings: (KeyBindingCommand) -> [KeyBinding?]
  ) {
    var index: [KeyBinding: KeyBindingCommand] = [:]
    for command in commands {
      for binding in bindings(command).compactMap({ $0 })
      where binding.modifiers.contains(.shift) && binding.key.count == 1 && binding.key.first?.isLetter == true {
        index[binding] = command
      }
    }
    walk(menu, index: index, editingText: editingText)
  }

  private static func walk(_ menu: NSMenu, index: [KeyBinding: KeyBindingCommand], editingText: Bool) {
    for item in menu.items {
      if let submenu = item.submenu { walk(submenu, index: index, editingText: editingText) }
      guard item.action.map({ !systemActions.contains(NSStringFromSelector($0)) }) ?? true,
        let chord = chord(of: item), let command = index[chord]
      else { continue }
      let allow = !editingText || WorkspaceAction.answersWhileEditingText(command.id)
      let letter = allow ? chord.key.uppercased() : chord.key
      guard letter.count == 1 else { continue }
      var modifiers = chord.modifiers
      if allow { modifiers.remove(.shift) }
      let mask = eventMask(modifiers)
      let same = item.keyEquivalent == letter
        && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == mask
      if !same {
        item.keyEquivalent = letter
        item.keyEquivalentModifierMask = mask
      }
      if allow { item.allowsAutomaticKeyEquivalentLocalization = false }
    }
  }

  /// `"h"` plus Shift and `"H"` plus Command are one chord.
  private static func chord(of item: NSMenuItem) -> KeyBinding? {
    let raw = item.keyEquivalent
    guard raw.count == 1, let character = raw.first, character.isLetter else { return nil }
    var modifiers: KeyModifiers = []
    let mask = item.keyEquivalentModifierMask
    if mask.contains(.command) { modifiers.insert(.command) }
    if mask.contains(.option) { modifiers.insert(.option) }
    if mask.contains(.control) { modifiers.insert(.control) }
    if mask.contains(.shift) || character.isUppercase { modifiers.insert(.shift) }
    guard modifiers.contains(.shift) else { return nil }
    return KeyBinding(String(character), modifiers)
  }

  private static func eventMask(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
    var mask: NSEvent.ModifierFlags = []
    if modifiers.contains(.command) { mask.insert(.command) }
    if modifiers.contains(.option) { mask.insert(.option) }
    if modifiers.contains(.control) { mask.insert(.control) }
    if modifiers.contains(.shift) { mask.insert(.shift) }
    return mask
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
