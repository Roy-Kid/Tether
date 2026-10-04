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

  @Test("Escape still cancels through the native button")
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
    #expect(surface.route(escape) != nil)
    // These offscreen windows do not take focus from the user's app.
    try #require(cancel.performKeyEquivalent(with: escape))
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
