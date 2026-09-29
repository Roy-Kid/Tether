import SwiftUI

#if os(macOS)
  import AppKit
  typealias PlatformWindow = NSWindow
#else
  import UIKit
  typealias PlatformWindow = UIWindow
#endif

/// The window a view's dialogs belong to.
///
/// A view asking a question means it of the window it is in: Settings'
/// "Forget this host key?" belongs on Settings, not on whichever window
/// happens to be in front. Only a question with no view behind it — a
/// handshake's — goes to the frontmost.
@MainActor
final class DialogAnchor {
  weak var window: PlatformWindow?
}

/// Finds the window for a ``DialogAnchor``. Draws nothing and takes no
/// touches.
#if os(macOS)
  struct DialogAnchorReader: NSViewRepresentable {
    let anchor: DialogAnchor

    func makeNSView(context: Context) -> Reader {
      let view = Reader()
      view.anchor = anchor
      return view
    }

    func updateNSView(_ view: Reader, context: Context) {
      view.anchor = anchor
      if let window = view.window { anchor.window = window }
    }

    final class Reader: NSView {
      weak var anchor: DialogAnchor?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { anchor?.window = window }
      }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
  }
#else
  struct DialogAnchorReader: UIViewRepresentable {
    let anchor: DialogAnchor

    func makeUIView(context: Context) -> Reader {
      let view = Reader()
      view.anchor = anchor
      view.isUserInteractionEnabled = false
      return view
    }

    func updateUIView(_ view: Reader, context: Context) {
      view.anchor = anchor
      if let window = view.window { anchor.window = window }
    }

    final class Reader: UIView {
      weak var anchor: DialogAnchor?

      override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { anchor?.window = window }
      }
    }
  }
#endif
