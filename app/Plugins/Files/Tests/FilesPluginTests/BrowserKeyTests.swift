#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import TetherTestSupport
  import Tether
  import TetherPluginKit

  @testable import FilesPlugin

  extension BrowserUITests {
    /// The browser as it is drawn, in a window, answering real key events —
    /// what a person pressing space in the inspector actually exercises.
    @MainActor
    @Suite("keys in the browser", .serialized, .appKitEventLoop)
    struct BrowserKeyTests {
      init() { _ = NSApplication.shared }

      private func context() -> TabContext {
        TabContext(
          id: UUID(),
          plugin: PluginContext(
            connection: nil, hostLabel: "lab", hostID: UUID(),
            openWorkspace: { _ in }, reconnect: { throw CancellationError() }),
          focus: {}, dismissAccessory: {}, present: { _ in }, dismissSheet: {})
      }

      private func outline(_ view: NSView, depth: Int = 0) -> String {
        guard depth < 6 else { return "" }
        let rect = view.bounds
        let label = view.accessibilityLabel() ?? ""
        let line = "\(String(repeating: " ", count: depth))\(type(of: view)) \(Int(rect.width))x\(Int(rect.height)) \(label)\n"
        return line + view.subviews.map { outline($0, depth: depth + 1) }.joined()
      }

      private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
      }

      private func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { editableField(in: $0) }.first
      }

      private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for sub in view.subviews {
          if let button = findButton(titled: title, in: sub) { return button }
        }
        return nil
      }

      private func press(_ characters: String, code: UInt16, in window: NSWindow,
                         base: String? = nil, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: base ?? characters, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
      }

      /// The pasteboard is the user's. A test that writes it puts the previous
      /// contents back, including when the assertion fails.
      private final class PasteboardSnapshot {
        private let items: [NSPasteboardItem]

        init() {
          items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
              if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
          }
        }

        func restore() {
          let board = NSPasteboard.general
          board.clearContents()
          if !items.isEmpty { board.writeObjects(items) }
        }
      }

    }
  }
#endif
