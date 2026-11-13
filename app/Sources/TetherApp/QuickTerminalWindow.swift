#if os(macOS)
  import AppKit
  import SwiftUI

  /// The quick terminal's own window. It is not the workspace window:
  /// summoning and hiding it never moves, restyles, resizes or
  /// full-screen-exits the main window (`QuickTerminalController`).
  ///
  /// A permanently non-activating panel: `.nonactivatingPanel` is in the
  /// style mask from `init` and nothing ever adds to or removes from that
  /// mask, so the panel takes key — and typed input — without making
  /// Tether the active app, on every Space, another app's full-screen one
  /// on another display included (`.canJoinAllSpaces`,
  /// `.fullScreenAuxiliary`). It is key-capable but never main: the app in
  /// front stays as it was. It always floats, whatever the main window's
  /// Keep on Top says; that setting is the main window's alone.
  class QuickTerminalWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    /// An overlay is never the app's main window: the app in front stays
    /// as it was. (`NSPanel` defaults this to false; said out loud so the
    /// contract does not rest on a default.)
    override var canBecomeMain: Bool { false }

    /// Hosting `root`, configured the way the overlay lives: no close,
    /// minimize or zoom button (dismissal is hide-only, through the
    /// controller), no frame autosave (the summoned size is the
    /// controller's own, remembered apart from the main window's frame).
    convenience init(hosting root: some View) {
      self.init(
        contentRect: NSRect(x: 0, y: 0, width: Chrome.windowWidth, height: 360),
        styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      title = "Tether"
      isReleasedWhenClosed = false
      // The overlay stays over other apps' windows and stays put when
      // Tether is not the active app; auto-hide is the controller's job.
      isFloatingPanel = true
      becomesKeyOnlyIfNeeded = false
      hidesOnDeactivate = false
      isExcludedFromWindowsMenu = true
      level = .floating
      collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      // Ordering out with the default animation waits on the window server.
      animationBehavior = .none
      titleVisibility = .hidden
      titlebarAppearsTransparent = true
      titlebarSeparatorStyle = .none
      standardWindowButton(.closeButton)?.isHidden = true
      standardWindowButton(.miniaturizeButton)?.isHidden = true
      standardWindowButton(.zoomButton)?.isHidden = true
      // Shorter than the document window, so a third of a laptop is allowed.
      contentMinSize = QuickTerminalController.minimumSize
      minSize = QuickTerminalController.minimumSize
      let hosting = NSHostingView(rootView: root)
      hosting.sizingOptions = []
      contentView = hosting
    }
  }
#endif
