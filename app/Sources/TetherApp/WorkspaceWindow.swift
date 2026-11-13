#if os(macOS)
  import AppKit
  import SwiftUI

  /// The workspace window: the app's document window, an `NSPanel` because
  /// that is what the workspace has always been. The quick terminal is a
  /// separate panel (`QuickTerminalWindow`) summoned over it; this window's
  /// frame, style, level and full-screen state are never touched by that.
  /// Ordinarily it is titled, resizable, full-screen capable, and remembered
  /// across launches.
  class WorkspaceWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// A panel does not offer a declined key to the menu bar. SwiftUI's
    /// ⇧⌘letter items are rewritten just before this runs; without the
    /// forward, Change Host never arrives while the terminal is first
    /// responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      if super.performKeyEquivalent(with: event) { return true }
      // A field keeps the keys the monitor declined. Forwarding them would
      // run the menu item anyway — ⌘1 would leave the field for a host.
      if WorkspaceKeyBindingMonitor.MonitorView.isEditingText(firstResponder) { return false }
      return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    /// Hosting `root`, opened at the size a new window opens at, or where
    /// `autosaveName` last remembered it.
    convenience init(hosting root: some View, autosaveName: String? = "workspace") {
      self.init(
        contentRect: NSRect(x: 0, y: 0, width: Chrome.windowWidth, height: Chrome.windowHeight),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      title = "Tether"
      isReleasedWhenClosed = false
      // Panel defaults are for inspectors. This one is the document.
      hidesOnDeactivate = false
      isFloatingPanel = false
      becomesKeyOnlyIfNeeded = false
      isExcludedFromWindowsMenu = false
      animationBehavior = .documentWindow
      tabbingMode = .disallowed
      collectionBehavior = [.fullScreenPrimary]
      // The content has no ideal size — a terminal fills what it is given —
      // so the window keeps its frame and only the minimum is the content's.
      contentMinSize = NSSize(width: Chrome.windowMinWidth, height: Chrome.windowMinHeight)
      let hosting = NSHostingView(rootView: root)
      hosting.sizingOptions = []
      contentView = hosting
      center()
      if let autosaveName {
        setFrameAutosaveName(autosaveName)
        setFrameUsingName(autosaveName)
      }
    }
  }
#endif
