#if os(macOS)
  import AppKit
  import SwiftUI

  /// What the red button does to the main window.
  ///
  /// The window is a view of sessions the app holds, not their owner: the
  /// tabs live as long as the process. But the view is not stateless — a
  /// password being asked for, a plugin waiting on a reconnect, the handler
  /// that disconnects everything on quit — and a `Window` scene that really
  /// closes throws all of that away with its views. So the window is put
  /// away, not closed, and comes back from the Dock exactly as it was.
  /// Nothing is lost, so there is nothing to confirm.
  enum MainWindowClose: Equatable {
    case hide
    /// A full-screen window is its own Space. Hidden there, it would leave
    /// that Space behind, black and empty; so it comes out first.
    case leaveFullScreenThenHide

    static func action(fullScreen: Bool) -> Self {
      fullScreen ? .leaveFullScreenThenHide : .hide
    }
  }

  /// Sits in front of SwiftUI's window delegate. Close becomes hide; every
  /// other message goes on to the delegate that was already there.
  final class HideInsteadOfClose: NSObject, NSWindowDelegate {
    weak var forwarded: NSWindowDelegate?
    private var hidesAfterFullScreen = false

    init(forwarding: NSWindowDelegate?) {
      forwarded = forwarding
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      switch MainWindowClose.action(fullScreen: sender.styleMask.contains(.fullScreen)) {
      case .hide:
        sender.orderOut(nil)
      case .leaveFullScreenThenHide:
        hidesAfterFullScreen = true
        sender.toggleFullScreen(nil)
      }
      return false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
      forwarded?.windowDidExitFullScreen?(notification)
      guard hidesAfterFullScreen, let window = notification.object as? NSWindow else { return }
      hidesAfterFullScreen = false
      window.orderOut(nil)
    }

    /// The main window back in front, from wherever it was put. False when
    /// it was already showing and there was nothing to bring back.
    @discardableResult
    static func reveal(_ window: NSWindow) -> Bool {
      guard !window.isVisible || window.isMiniaturized else { return false }
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      // The click that asked for this activated the app before the window
      // was there to bring its Space forward; with the window up, once more.
      NSApp.activate(ignoringOtherApps: true)
      return true
    }

    /// The window this delegate guards, among the app's — Settings and any
    /// panel are the others, and never stand in for it.
    static func mainWindow(in app: NSApplication) -> NSWindow? {
      app.windows.first { $0.delegate is HideInsteadOfClose }
    }

    override func responds(to selector: Selector!) -> Bool {
      if super.responds(to: selector) { return true }
      return forwarded?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
      if super.responds(to: selector) { return nil }
      return forwarded
    }
  }

  /// What the window this view is in is doing — on screen or put away, key
  /// or not — for views that would have asked a scene. It also hands the
  /// window the colour scheme the content chose, so sheets and the traffic
  /// lights match a grid forced light or dark.
  struct WindowState: NSViewRepresentable {
    struct Value: Equatable {
      var shown = false
      var key = false
    }
    var scheme: ColorScheme?
    let onChange: @MainActor (Value) -> Void

    func makeNSView(context: Context) -> Hook { Hook(onChange: onChange) }
    func updateNSView(_ view: Hook, context: Context) {
      view.onChange = onChange
      view.apply(scheme: scheme)
    }

    final class Hook: NSView {
      var onChange: @MainActor (Value) -> Void
      private var value = Value()
      private var scheme: ColorScheme?

      init(onChange: @escaping @MainActor (Value) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) { fatalError("not from a nib") }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
          for name in [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
          ] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: window)
          }
        }
        apply(scheme: scheme)
        report()
      }

      @objc private func changed() { report() }

      /// On the next turn: a window change can arrive inside a view update.
      private func report() {
        let next = Value(
          shown: window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false,
          key: window?.isKeyWindow ?? false)
        guard next != value else { return }
        value = next
        RunLoop.main.perform { [weak self] in
          MainActor.assumeIsolated { self?.onChange(next) }
        }
      }

      func apply(scheme: ColorScheme?) {
        self.scheme = scheme
        window?.appearance = scheme.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
      }
    }
  }

  /// What a double-click on a titlebar does, as the person chose it in
  /// Desktop & Dock. The strip is drawn by the app, so the system's own
  /// handling never sees the click; reading the choice is how it still holds.
  enum TitlebarDoubleClick: Equatable {
    case zoom
    case minimize
    case nothing

    static let actionKey = "AppleActionOnDoubleClick"
    /// The older switch, from before there was a choice of three.
    static let legacyMinimizeKey = "AppleMiniaturizeOnDoubleClick"

    /// "Fill" (macOS 15) has no public call; zoom is the nearest a window
    /// can do by itself. Unset means the system default, which is zoom.
    static func action(setting: String?, legacyMinimize: Bool?) -> Self {
      switch setting {
      case "Minimize": .minimize
      case "None": .nothing
      case "Maximize", "Fill": .zoom
      default: legacyMinimize == true ? .minimize : .zoom
      }
    }

    static func chosen(in defaults: UserDefaults = .standard) -> Self {
      action(
        setting: defaults.string(forKey: actionKey),
        legacyMinimize: defaults.object(forKey: legacyMinimizeKey) as? Bool)
    }

    @MainActor
    func perform(on window: NSWindow) {
      switch self {
      case .zoom: window.zoom(nil)
      case .minimize: window.miniaturize(nil)
      case .nothing: break
      }
    }
  }

  /// A press on titlebar the app draws over — the strip beside the tabs, or
  /// the empty row when the strip is hidden — does what a press on any Mac
  /// titlebar does: drags the window, or on a double-click, what the person
  /// chose.
  @MainActor
  enum TitlebarPress {
    static func handle(_ event: NSEvent, in window: NSWindow?) {
      guard let window else { return }
      if event.clickCount == 2 {
        TitlebarDoubleClick.chosen().perform(on: window)
      } else {
        window.performDrag(with: event)
      }
    }
  }
#endif
