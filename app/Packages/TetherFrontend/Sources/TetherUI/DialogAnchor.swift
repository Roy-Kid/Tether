import SwiftUI

#if os(macOS)
  import AppKit
  typealias PlatformWindow = NSWindow
#else
  import UIKit
  typealias PlatformWindow = UIWindow
#endif

/// Where a dialog belongs.
///
/// A view asking a question means it of the window it is in: Settings'
/// "Forget this host key?" belongs on Settings, not on whichever window
/// happens to be in front. A question with no view behind it goes to the
/// frontmost. A terminal's reconnect question is narrower than its window:
/// it covers that terminal, and the rest of the window stays usable.
@MainActor
public final class DialogAnchor {
  weak var window: PlatformWindow?
  #if os(macOS)
    /// The terminal (or other region) this dialog covers. Nil covers the window.
    weak var view: NSView?
    /// Questions asked with this anchor belong on `view`.
    var limitsToView = false
    /// The covered view moved, or left the window.
    var onRegionChange: (() -> Void)?
    /// Fired once, when a view-scoped anchor first has a view on screen.
    var whenViewReady: (() -> Void)?
  #endif

  public init() {}

  /// A reconnect question covers the terminal this anchor is read from.
  public func coverItsView() {
    #if os(macOS)
      limitsToView = true
    #endif
  }
}

/// Finds the window for a ``DialogAnchor``. Draws nothing and takes no
/// touches.
#if os(macOS)
  public struct DialogAnchorReader: NSViewRepresentable {
    public let anchor: DialogAnchor
    /// This window is the one in front, so its terminal is the region.
    public var claimsView = false

    public init(anchor: DialogAnchor, claimsView: Bool = false) {
      self.anchor = anchor
      self.claimsView = claimsView
    }

    public func makeNSView(context: Context) -> Reader {
      let view = Reader()
      view.anchor = anchor
      view.claimsView = claimsView
      return view
    }

    public func updateNSView(_ view: Reader, context: Context) {
      view.anchor = anchor
      view.claimsView = claimsView
      view.claim()
    }

    public final class Reader: NSView {
      weak var anchor: DialogAnchor?
      var claimsView = false

      public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
          guard let anchor, anchor.view === self else { return }
          anchor.view = nil
          anchor.onRegionChange?()
        } else {
          claim()
        }
      }

      public override func layout() {
        super.layout()
        claim()
      }

      public override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func claim() {
        guard let anchor else { return }
        if let window { anchor.window = window }
        guard anchor.limitsToView else { return }
        if claimsView, window != nil {
          anchor.view = self
          let ready = anchor.whenViewReady
          anchor.whenViewReady = nil
          ready?()
          anchor.onRegionChange?()
        } else if anchor.view === self {
          anchor.view = nil
          anchor.onRegionChange?()
        }
      }
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
