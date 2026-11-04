#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TetherTestSupport
import Tether
import TetherPluginKit
import TetherUI
@testable import TmuxPlugin

@MainActor
@Suite("Picker keyboard actions", .serialized, .appKitEventLoop)
struct PickerKeyTests {

  private func press(_ characters: String, base: String? = nil, code: UInt16,
    flags: NSEvent.ModifierFlags = [], in window: NSWindow) async throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: base ?? characters,
      isARepeat: false, keyCode: code))
    if !PickerShortcuts.handle(event) { window.sendEvent(event) }
    try await Task.sleep(for: .milliseconds(70))
  }

  private func settle(until condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
  }

  private func button(_ title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    return view.subviews.lazy.compactMap { button(title, in: $0) }.first
  }

  private func textField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { textField(in: $0) }.first
  }
}

@MainActor
private final class PickerTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
#endif
