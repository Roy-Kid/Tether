#if os(macOS)
  import AppKit
  import SwiftUI

  /// The window a workspace lives in. A panel, because only a panel can be
  /// shown as an overlay — key without making this the active app, over any
  /// Space, another app's full-screen one on another display included — and
  /// the quick terminal is one of these shown that way, over the same tabs
  /// (`QuickTerminalController`). The ordinary window is another: titled,
  /// resizable, full-screen capable, remembered across launches.
  class WorkspaceWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    /// An overlay is not the app's main window: the app in front stays as it was.
    override var canBecomeMain: Bool { !styleMask.contains(.nonactivatingPanel) }

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
