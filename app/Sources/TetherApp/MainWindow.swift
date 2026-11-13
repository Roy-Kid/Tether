#if os(macOS)
  import AppKit
  import SwiftUI

  /// What the close button does to the main window.
  ///
  /// Settings → General → When the Window Closes. Quit ends the app, through
  /// the same live-terminal question as ⌘Q. Hide puts the window away and
  /// leaves the Dock: the menu-bar icon is the way back, and the sessions
  /// stay. A full-screen window is its own Space, so Hide leaves that Space
  /// before the window goes, or the Space would stay behind, black and empty.
  enum MainWindowClose: Equatable {
    case quit
    case hide
    case leaveFullScreenThenHide

    static func action(fullScreen: Bool, setting: String = CloseWindowPreference.chosen) -> Self {
      guard setting != CloseWindowPreference.quit else { return .quit }
      return fullScreen ? .leaveFullScreenThenHide : .hide
    }
  }

  /// Quit, or stay running with only the menu-bar icon.
  ///
  /// The key and the two values live together so the picker and the close
  /// path name the same strings. Anything unrecognized hides: a mistyped
  /// value must not quit over someone's sessions.
  enum CloseWindowPreference {
    static let key = "closeWindow"
    static let quit = "quit"
    static let menuBar = "menuBar"
    static let `default` = menuBar

    static var chosen: String {
      UserDefaults.standard.string(forKey: key) ?? `default`
    }
  }

  /// The Dock icon, while Hide has put the main window away.
  ///
  /// The policy change is the real app's. A test runner shares this code and
  /// must not lose its own Dock icon or be told to quit. The notifications
  /// still post, so the menu-bar icon can be required and released either way.
  @MainActor
  enum AppPresence {
    static let willLeaveDock = Notification.Name("Tether.willLeaveDock")
    static let didReturnToDock = Notification.Name("Tether.didReturnToDock")

    /// The close button hid the window, and it has not been shown as the
    /// main window since. The Dock waits if another window, such as Settings,
    /// is still open.
    private(set) static var hiddenByClose = false

    static var isTether: Bool { Bundle.main.bundleIdentifier == "Roy-Kid.Tether" }

    /// Hide removes the Dock icon only once nothing else is on screen.
    static func hidesDock(setting: String, mainVisible: Bool, otherVisible: Bool) -> Bool {
      setting != CloseWindowPreference.quit && !mainVisible && !otherVisible
    }

    static func anotherWindowIsOpen(besides main: NSWindow?) -> Bool {
      NSApp.windows.contains { window in
        guard window !== main, window.isVisible, window.styleMask.contains(.titled) else { return false }
        return window.level == .normal || window.level == .floating
      }
    }

    static func rememberHiddenByClose() {
      hiddenByClose = true
    }

    /// The menu-bar icon is posted up before the Dock icon goes, so there is
    /// always something to click.
    static func leaveDock(for window: NSWindow) {
      hiddenByClose = true
      NotificationCenter.default.post(name: willLeaveDock, object: window)
      guard isTether else { return }
      NSApp.setActivationPolicy(.accessory)
    }

    static func returnToDock() {
      hiddenByClose = false
      if isTether, NSApp.activationPolicy() == .accessory {
        NSApp.setActivationPolicy(.regular)
      }
      NotificationCenter.default.post(name: didReturnToDock, object: nil)
    }

    /// Quit from the close button. Cancelled, the window is still there,
    /// because the close was refused rather than performed.
    static func quit() {
      guard isTether else { return }
      NSApp.terminate(nil)
    }
  }

  /// Sits in front of SwiftUI's window delegate. Close becomes Quit or Hide;
  /// every other message goes on to the delegate that was already there.
  @MainActor
  final class HideInsteadOfClose: NSObject, NSWindowDelegate {
    /// AppKit asks `responds(to:)` off the main actor. The delegate it
    /// forwards to is only installed and used on the main thread.
    nonisolated(unsafe) weak var forwarded: NSWindowDelegate?
    private var hidesAfterFullScreen = false

    init(forwarding: NSWindowDelegate?) {
      forwarded = forwarding
    }

    /// Posted before a hide, with the window as the object. The quick terminal
    /// puts that window back at its own frame first, so one put away while
    /// summoned comes back there.
    static let willHide = Notification.Name("Tether.mainWindowWillHide")

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      switch MainWindowClose.action(fullScreen: sender.styleMask.contains(.fullScreen)) {
      case .quit:
        AppPresence.quit()
      case .hide:
        hide(sender)
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
      hide(window)
    }

    /// Put away, then leave the Dock once no other window is left to show.
    private func hide(_ window: NSWindow) {
      NotificationCenter.default.post(name: Self.willHide, object: window)
      window.orderOut(nil)
      let others = AppPresence.anotherWindowIsOpen(besides: window)
      if AppPresence.hidesDock(setting: CloseWindowPreference.chosen, mainVisible: false, otherVisible: others) {
        AppPresence.leaveDock(for: window)
      } else {
        AppPresence.rememberHiddenByClose()
      }
    }

    /// The main window back in front, and the Dock icon with it. False when
    /// it was already showing and there was nothing to bring back.
    @discardableResult
    static func reveal(_ window: NSWindow) -> Bool {
      AppPresence.returnToDock()
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
      var orderedIn = false
      var miniaturized = false
      var renderVisible = false
      var keyWithinHost = false

      var workspaceHostState: WorkspaceHostState {
        WorkspaceHostState(orderedIn: orderedIn, miniaturized: miniaturized,
          renderVisible: renderVisible, keyWithinHost: keyWithinHost)
      }
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
          key: window?.isKeyWindow ?? false,
          orderedIn: window?.isVisible ?? false,
          miniaturized: window?.isMiniaturized ?? false,
          renderVisible: window?.occlusionState.contains(.visible) ?? false,
          keyWithinHost: window.map { NativeWorkspaceHostBridge.keyIsWithin($0) } ?? false)
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

  /// Native lifetime bridge independent of SwiftUI mount/occlusion. Losing
  /// render visibility never means that a host was ordered out.
  @MainActor
  final class NativeWorkspaceHostBridge: NSObject {
    private weak var window: NSWindow?
    private weak var interaction: WorkspaceInteraction?
    private let id: UUID

    init(window: NSWindow, interaction: WorkspaceInteraction, id: UUID) {
      self.window = window
      self.interaction = interaction
      self.id = id
      super.init()
      for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification,
        NSWindow.didEndSheetNotification] {
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: window)
      }
      NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
      refresh()
    }

    static func keyIsWithin(_ window: NSWindow) -> Bool {
      if window.isKeyWindow { return true }
      var key = NSApp.keyWindow
      while let candidate = key {
        if candidate === window { return true }
        key = candidate.sheetParent ?? candidate.parent
      }
      return false
    }

    @objc private func changed() { refresh() }
    @objc private func closing() { interaction?.unregister(id: id) }

    func refresh() {
      guard let window else { return }
      interaction?.update(id: id, state: WorkspaceHostState(orderedIn: window.isVisible,
        miniaturized: window.isMiniaturized, renderVisible: window.occlusionState.contains(.visible),
        keyWithinHost: Self.keyIsWithin(window)))
    }

    deinit { NotificationCenter.default.removeObserver(self) }
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
