#if os(macOS)
import AppKit
import Testing
@testable import TetherUI

@MainActor
@Suite("Dialog keyboard confirmation", .serialized)
struct DialogKeyboardTests {
  private func event(_ key: String, code: UInt16, in window: NSWindow,
    modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
      charactersIgnoringModifiers: key, isARepeat: repeated, keyCode: code))
  }

  private func window() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.orderFrontRegardless()
    return window
  }

  private func settle(until condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
  }

  private func button(_ title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    return view.subviews.lazy.compactMap { button(title, in: $0) }.first
  }

  private func fields(in view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField, field.isEditable { return [field] }
    return view.subviews.flatMap { fields(in: $0) }
  }

  @Test("input fields fill the accessory width regardless of their text",
    arguments: ["", "Terminal 1", String(repeating: "Long terminal name ", count: 20)],
    [[Dialog.Field.Kind.text], [.password], [.code], [.text, .password, .code]])
  func inputFieldLayout(initial: String, kinds: [Dialog.Field.Kind]) async throws {
    let host = window()
    let anchor = DialogAnchor()
    anchor.window = host
    let surface = PlatformDialogSurface()
    let queue = DialogQueue(surface: surface)
    let dialog = Dialog(title: "Input", fields: kinds.map { Dialog.Field("", kind: $0, initial: initial) },
      actions: [.cancel(), Dialog.Action("Save")])
    let task = Task { await queue.ask(dialog, in: anchor) }
    defer { task.cancel(); surface.withdraw(); host.orderOut(nil) }
    try await settle { host.attachedSheet?.isVisible == true }
    let sheet = try #require(host.attachedSheet)
    let content = try #require(sheet.contentView)
    content.layoutSubtreeIfNeeded()
    let boxes = fields(in: content)
    try #require(boxes.count == kinds.count)
    for field in boxes {
      #expect(field.frame.width >= UIStyle.treeWidth - 1)
      #expect(field.frame.height >= UIStyle.controlHeight - 1)
      let rect = field.convert(field.bounds, to: content)
      #expect(content.bounds.contains(rect))
    }
    #expect(Set(boxes.map { $0.frame.width }).count == 1)
    #expect(sheet.frame.width < host.frame.width, "long names scroll inside the field")
  }

  @Test("Return and keypad Enter save edited input; Escape cancels", arguments: [36, 76, 53])
  func inputKeyboard(code: Int) async throws {
    let host = window()
    let anchor = DialogAnchor()
    anchor.window = host
    let surface = PlatformDialogSurface()
    let queue = DialogQueue(surface: surface)
    var saved: [String] = []
    var cancelled = 0
    let dialog = Dialog.input("Rename", field: Dialog.Field("Name", initial: "Terminal 1"),
      verb: "Save", cancel: { cancelled += 1 }) { saved.append($0) }
    let task = Task { await queue.ask(dialog, in: anchor) }
    defer { task.cancel(); surface.withdraw(); host.orderOut(nil) }
    try await settle { host.attachedSheet?.isVisible == true }
    let sheet = try #require(host.attachedSheet)
    let field = try #require(fields(in: sheet.contentView!).first)
    #expect(sheet.initialFirstResponder === field)
    sheet.makeFirstResponder(field)
    let editor = try #require(field.currentEditor() as? NSTextView)
    let text = code == 53 ? "\u{1b}" : code == 76 ? "\u{3}" : "\r"
    let key = try event(text, code: UInt16(code), in: sheet)

    editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    #expect(surface.route(key) != nil, "composition handles Enter and Escape before the dialog")
    editor.unmarkText()
    editor.selectAll(nil)
    editor.insertText("Renamed terminal", replacementRange: editor.selectedRange())
    #expect(surface.route(try event(text, code: UInt16(code), in: host)) != nil)
    #expect(surface.route(try event(text, code: UInt16(code), in: sheet, modifiers: .shift)) != nil)
    #expect(surface.route(try event(text, code: UInt16(code), in: sheet, repeated: true)) == nil)
    #expect(saved.isEmpty && cancelled == 0)

    try #require(surface.route(key) == nil)
    _ = surface.route(key)
    try await settle { !saved.isEmpty || cancelled > 0 }
    let reply = await task.value
    if code == 53 {
      #expect(reply?.role == .cancel)
      #expect(saved.isEmpty && cancelled == 1)
    } else {
      #expect(reply?.isAffirmative == true)
      #expect(saved == ["Renamed terminal"])
      #expect(cancelled == 0)
    }
    #expect(surface.route(key) != nil)
  }

  @Test("Enter, keypad Enter and a second Cmd+W confirm exactly once", arguments: [36, 76, 13])
  func confirm(code: Int) async throws {
    let host = window()
    let anchor = DialogAnchor()
    anchor.window = host
    let surface = PlatformDialogSurface()
    let queue = DialogQueue(surface: surface)
    var confirmed = 0
    let dialog = Dialog.confirm("Close Terminal 1?", verb: "Close", role: .destructive,
      shortcuts: [.enter, .command("w")]) { confirmed += 1 }
    let task = Task { await queue.ask(dialog, in: anchor) }
    defer { task.cancel(); surface.withdraw(); host.orderOut(nil) }
    try await settle { host.attachedSheet?.isVisible == true }
    let sheet = try #require(host.attachedSheet)
    let text = code == 13 ? "w" : code == 76 ? "\u{3}" : "\r"
    let modifiers: NSEvent.ModifierFlags = code == 13 ? .command : []

    // Holding the original shortcut is consumed without accepting the dialog.
    #expect(surface.route(try event(text, code: UInt16(code), in: sheet,
      modifiers: modifiers, repeated: true)) == nil)
    #expect(confirmed == 0)
    // The parent terminal and modified variants do not confirm the sheet.
    #expect(surface.route(try event(text, code: UInt16(code), in: host,
      modifiers: modifiers)) != nil)
    #expect(surface.route(try event(text, code: UInt16(code), in: sheet,
      modifiers: modifiers.union(.shift))) != nil)
    #expect(confirmed == 0)

    let confirm = try event(text, code: UInt16(code), in: sheet, modifiers: modifiers)
    #expect(surface.route(confirm) == nil, "the confirming key must not reach terminal input")
    _ = surface.route(confirm)
    try await settle { confirmed == 1 }
    #expect(await task.value?.isAffirmative == true)
    #expect(confirmed == 1)
    #expect(surface.route(confirm) != nil, "the dialog releases its shortcut handler on dismissal")
  }

  @Test("Escape invokes the native cancel button through the scoped handler")
  func nativeEscape() async throws {
    let host = window()
    let anchor = DialogAnchor()
    anchor.window = host
    let surface = PlatformDialogSurface()
    let queue = DialogQueue(surface: surface)
    var confirmed = false
    var cancelled = false
    let dialog = Dialog.confirm("Close Terminal 1?", verb: "Close", role: .destructive,
      shortcuts: [.enter, .command("w")], cancel: { cancelled = true }) { confirmed = true }
    let task = Task { await queue.ask(dialog, in: anchor) }
    defer { task.cancel(); surface.withdraw(); host.orderOut(nil) }
    try await settle { host.attachedSheet?.isVisible == true }
    let sheet = try #require(host.attachedSheet)
    let cancel = try #require(button("Cancel", in: sheet.contentView!))
    #expect(cancel.keyEquivalent == "\u{1b}")
    let escape = try event("\u{1b}", code: 53, in: sheet)
    #expect(surface.route(escape) == nil)
    try await settle { cancelled }
    #expect(await task.value?.role == .cancel)
    #expect(!confirmed)
  }

  @Test("other destructive dialogs and withdrawn confirmations do not accept these keys")
  func scopedShortcuts() async throws {
    let host = window()
    let anchor = DialogAnchor()
    anchor.window = host
    let surface = PlatformDialogSurface()
    let queue = DialogQueue(surface: surface)
    var deleted = false
    let task = Task { await queue.ask(Dialog.confirm("Delete items?", verb: "Delete", role: .destructive) {
      deleted = true
    }, in: anchor) }
    defer { task.cancel(); surface.withdraw(); host.orderOut(nil) }
    try await settle { host.attachedSheet?.isVisible == true }
    let sheet = try #require(host.attachedSheet)
    #expect(surface.route(try event("\r", code: 36, in: sheet)) != nil)
    #expect(surface.route(try event("w", code: 13, in: sheet, modifiers: .command)) != nil)
    task.cancel()
    #expect(await task.value == nil)
    #expect(!deleted)
  }
}
#endif
