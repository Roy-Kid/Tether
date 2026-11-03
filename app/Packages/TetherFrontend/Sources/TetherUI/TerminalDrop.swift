#if os(macOS)
  import AppKit
  import SwiftUI

  /// What a terminal takes when something is dropped on it: the pasteboard
  /// types it accepts, and what to do with a drop that carries one.
  ///
  /// AppKit's, not SwiftUI's. SwiftUI hands a drop over as one provider per
  /// item and keeps nothing else from an item that holds a file promise, so a
  /// row dragged out of a list had to carry its path on an extra item — and
  /// the drag then counted one file as two. Here the whole pasteboard is read.
  public struct TerminalDropHandler {
    public var types: [NSPasteboard.PasteboardType]
    public var perform: @MainActor (NSPasteboard) -> Bool

    public init(types: [NSPasteboard.PasteboardType], perform: @escaping @MainActor (NSPasteboard) -> Bool) {
      self.types = types
      self.perform = perform
    }
  }

  private struct TerminalDropKey: EnvironmentKey {
    static var defaultValue: TerminalDropHandler? { nil }
  }

  extension EnvironmentValues {
    var terminalDrop: TerminalDropHandler? {
      get { self[TerminalDropKey.self] }
      set { self[TerminalDropKey.self] = newValue }
    }
  }

  extension View {
    public func terminalDrop(_ handler: TerminalDropHandler) -> some View {
      environment(\.terminalDrop, handler)
    }
  }
#endif
