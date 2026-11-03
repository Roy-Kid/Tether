#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import TetherUI

/// The hotkey terminal: the main window, summoned. The shortcut shows that
/// window on the display under the pointer, as an overlay — key without
/// making this the active app, so it can join any Space, another app's
/// full-screen one on another display included. Closing it puts the window
/// back at the frame it had. The Dock and the menu bar open it there; only
/// the shortcut summons it. Its summoned size is its own (`quickSize`):
/// dragged once, it comes back that size. Hiding never closes a session.
@MainActor @Observable
final class QuickTerminalController: NSObject {
  var enabled: Bool {
    didSet {
      defaults.set(enabled, forKey: "quickTerminal.enabled")
      if !enabled { hide() }
      refreshHotKeys()
      refreshStatusItem()
    }
  }
  /// Keeps the main window above other apps' windows. While summoned, the
  /// window floats whatever this says.
  var alwaysOnTop: Bool {
    didSet {
      defaults.set(alwaysOnTop, forKey: "window.alwaysOnTop")
      if !quick { window?.level = alwaysOnTop ? .floating : .normal }
    }
  }
  var autoHide: Bool {
    didSet { defaults.set(autoHide, forKey: "quickTerminal.autoHide") }
  }
  /// The menu-bar mark. Off, and the shortcut still works. Hide in When the
  /// Window Closes puts the icon up anyway, until the window is the main
  /// window again: with the Dock gone, the icon is the way back.
  var showsMenuBarIcon: Bool {
    didSet {
      defaults.set(showsMenuBarIcon, forKey: "quickTerminal.menuBarIcon")
      refreshStatusItem()
    }
  }
  /// Hide has taken the Dock icon. The menu-bar mark stays until the window
  /// comes back as the main window.
  private var holdsMenuBarIcon = false
  var recordingShortcut = false {
    didSet { refreshHotKeys() }
  }
  private(set) var shortcutProblem: String?

  /// The one workspace window.
  @ObservationIgnored private weak var window: NSWindow?
  /// Where that window was before the shortcut moved it, and how it was shown.
  @ObservationIgnored private var home: Home?
  /// Summoned onto the pointer's display. The Dock and the menu bar are not this.
  private(set) var quick = false
  /// Full screen has to finish leaving before the window can move.
  @ObservationIgnored private var afterFullScreenExit: FullScreenFollowUp?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var previousApp: NSRunningApplication?
  /// The summoned size as it was last dragged. Nil until a drag, or after
  /// Reset: full width and the top third of the display.
  @ObservationIgnored private var quickSize: NSSize?
  /// A frame this controller set, which is not a drag and not a new display.
  @ObservationIgnored private var placing = false
  @ObservationIgnored private var bindingsStore: KeyBindingStore?
  @ObservationIgnored private var bindings: [KeyBinding] = []
  @ObservationIgnored private(set) var hotKeys: [EventHotKeyRef] = []
  /// The key codes `hotKeys` were registered for, read from the
  /// ASCII-capable layout that an input source change may replace.
  @ObservationIgnored private var registeredCodes: [UInt16?] = []
  @ObservationIgnored private var eventHandler: EventHandlerRef?
  @ObservationIgnored private var statusItem: NSStatusItem?
  @ObservationIgnored private var showingStatusMenu = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    enabled = defaults.object(forKey: "quickTerminal.enabled") as? Bool ?? true
    alwaysOnTop = defaults.bool(forKey: "window.alwaysOnTop")
    autoHide = defaults.object(forKey: "quickTerminal.autoHide") as? Bool ?? true
    showsMenuBarIcon = defaults.object(forKey: "quickTerminal.menuBarIcon") as? Bool ?? true
    quickSize = Self.storedSize(in: defaults)
    super.init()
  }

  private static let widthKey = "quickTerminal.width"
  private static let heightKey = "quickTerminal.height"

  private static func storedSize(in defaults: UserDefaults) -> NSSize? {
    let width = defaults.double(forKey: widthKey)
    let height = defaults.double(forKey: heightKey)
    guard width > 0, height > 0 else { return nil }
    return NSSize(width: width, height: height)
  }

  /// Whether the shortcut has a window to move.
  private var canShow: Bool { window != nil }

  /// Summoned, or about to be once full screen has finished leaving.
  var isQuick: Bool { quick || afterFullScreenExit == .presentQuick }

  /// Whether the window is up on the pointer's display.
  var isShown: Bool { quick && window?.isVisible == true }

  /// The workspace window. The shortcut moves this one; nothing else is made.
  func attach(to window: NSWindow) {
    guard self.window !== window else { return }
    if let old = self.window { unobserve(old) }
    self.window = window
    if !quick { window.level = alwaysOnTop ? .floating : .normal }
    for name in Self.windowNotes {
      NotificationCenter.default.addObserver(self, selector: selector(for: name), name: name, object: window)
    }
    startListening()
  }

  private static let windowNotes: [Notification.Name] = [
    NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
    NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification,
    HideInsteadOfClose.willHide,
  ]

  private func selector(for name: Notification.Name) -> Selector {
    switch name {
    case NSWindow.didChangeScreenNotification: #selector(screenChanged)
    case NSWindow.didEndLiveResizeNotification: #selector(resized)
    case NSWindow.didExitFullScreenNotification: #selector(exitedFullScreen)
    case HideInsteadOfClose.willHide: #selector(windowWillHide(_:))
    default: #selector(resignedKey)
    }
  }

  private func unobserve(_ window: NSWindow) {
    for name in Self.windowNotes {
      NotificationCenter.default.removeObserver(self, name: name, object: window)
    }
  }

  private var listening = false

  private func startListening() {
    if !listening {
      listening = true
      NotificationCenter.default.addObserver(self, selector: #selector(resignedKey),
        name: NSApplication.didResignActiveNotification, object: NSApp)
      NotificationCenter.default.addObserver(self, selector: #selector(holdMenuBarIcon(_:)),
        name: AppPresence.willLeaveDock, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(releaseMenuBarIcon),
        name: AppPresence.didReturnToDock, object: nil)
      DistributedNotificationCenter.default().addObserver(self, selector: #selector(keyboardChanged),
        name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
    }
    refreshHotKeys()
    refreshStatusItem()
  }

  /// Observe the store outside SwiftUI's rendering cycle: the global shortcut
  /// must update even while the main window is hidden behind Settings.
  func useBindings(_ store: KeyBindingStore) {
    guard bindingsStore !== store else { return }
    bindingsStore = store
    observeBindings()
  }

  private func observeBindings() {
    guard let store = bindingsStore else { return }
    let next = withObservationTracking {
      store.bindings(for: WorkspaceAction.quickTerminal.command)
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in self?.observeBindings() }
    }
    configure(next)
  }

  func configure(_ requested: [KeyBinding?]) {
    let next = requested.compactMap { $0 }
    guard bindings != next else { return }
    bindings = next
    refreshHotKeys()
    refreshStatusItem()
  }

  /// The Carbon hotkey runs inside the window server's event. Show and hide
  /// on the next turn, after that event has returned.
  fileprivate func scheduleToggleFromHotKey() {
    DispatchQueue.main.async { [weak self] in
      self?.toggle()
    }
  }

  func toggle() {
    guard enabled else { return }
    if afterFullScreenExit != nil {
      leaveQuick(showMain: false)
      return
    }
    guard let window else { return }
    if isShown && window.isKeyWindow && window.isOnActiveSpace {
      leaveQuick(showMain: false)
    } else {
      show()
    }
  }

  /// The Dock, the menu bar, and any reopen: the main window, at its own frame.
  func showAsMainWindow() {
    if quick || afterFullScreenExit != nil {
      leaveQuick(showMain: true)
      return
    }
    guard let window else { return }
    orderMain(window)
  }

  private func show() {
    guard enabled, let window else { return }
    if window.styleMask.contains(.fullScreen), !quick {
      beginFromFullScreen(window, then: .presentQuick)
      return
    }
    if !quick { rememberHome(window) }
    presentQuick(window)
  }

  /// Full screen is its own Space. Leave it, then move; closing the summon
  /// goes back into it.
  private func beginFromFullScreen(_ window: NSWindow, then follow: FullScreenFollowUp) {
    if home == nil { rememberHome(window) }
    afterFullScreenExit = follow
    window.toggleFullScreen(nil)
  }

  @objc private func exitedFullScreen() {
    guard let follow = afterFullScreenExit, let window else { return }
    afterFullScreenExit = nil
    switch follow {
    case .presentQuick:
      home?.frame = window.frame
      presentQuick(window)
    case .restore:
      let full = home?.fullScreen == true
      home = nil
      if full { window.toggleFullScreen(nil) }
    case .showMain:
      let full = home?.fullScreen == true
      home = nil
      orderMain(window)
      if full { window.toggleFullScreen(nil) }
    }
  }

  private func presentQuick(_ window: NSWindow) {
    guard enabled else { return }
    quick = true
    let front = NSWorkspace.shared.frontmostApplication
    if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      previousApp = front
    } else {
      previousApp = nil
    }
    applyQuickStyle(window)
    if window.isMiniaturized { window.deminiaturize(nil) }
    // Showing on a Space that is no longer in front: come here rather than
    // send the person back there. Re-framed while still there, a window is
    // put on the pointer's display instead of the one asked for.
    if window.isVisible && !window.isOnActiveSpace { window.orderOut(nil) }
    // The display under the pointer, wherever the window was.
    let screen = Self.mouseScreen() ?? window.screen ?? NSScreen.main
    placing = true
    if let screen { place(window, on: screen) }
    window.orderFrontRegardless()
    // Ordering a hidden window on screen can hand it back narrower than it
    // was set — measured with Stage Manager on: 2560 points asked for, 2316
    // given, whatever the content view. A frame set while it is up stays.
    if let screen { place(window, on: screen) }
    placing = false
    window.makeKey()
    // The grid follows the view's bounds. A frame set here does not otherwise
    // reach it, and the shell keeps the size it had.
    refit(window)
  }

  /// The frame and the way the window was shown, before the shortcut.
  private func rememberHome(_ window: NSWindow) {
    home = Home(
      frame: window.frame,
      visible: window.isVisible && !window.isMiniaturized,
      miniaturized: window.isMiniaturized,
      fullScreen: window.styleMask.contains(.fullScreen),
      collectionBehavior: window.collectionBehavior,
      minSize: window.minSize,
      contentMinSize: window.contentMinSize,
      animationBehavior: window.animationBehavior,
      autosaveName: window.frameAutosaveName)
  }

  /// Key without activating, on every Space, never full screen itself.
  /// No frame autosave: the summoned size is `quickSize`, and the main
  /// window's frame must stay what it was.
  private func applyQuickStyle(_ window: NSWindow) {
    (window as? NSPanel)?.styleMask.insert(.nonactivatingPanel)
    window.level = .floating
    var behavior = window.collectionBehavior
    behavior.remove([.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone, .primary, .auxiliary])
    behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    window.collectionBehavior = behavior
    // Ordering out with the default animation waits on the window server.
    window.animationBehavior = .none
    window.setFrameAutosaveName("")
    // The document window's minimum is too tall for a third of a laptop.
    window.contentMinSize = Self.minimumSize
    window.minSize = Self.minimumSize
  }

  private func restoreStyle(_ window: NSWindow, _ saved: Home) {
    (window as? NSPanel)?.styleMask.remove(.nonactivatingPanel)
    window.level = alwaysOnTop ? .floating : .normal
    window.collectionBehavior = saved.collectionBehavior
    window.animationBehavior = saved.animationBehavior
    window.contentMinSize = saved.contentMinSize
    window.minSize = saved.minSize
  }

  /// Back to the frame the window had. `showMain` leaves it on screen there;
  /// the shortcut returns it to the visibility it had.
  private func leaveQuick(showMain: Bool) {
    if afterFullScreenExit != nil {
      afterFullScreenExit = showMain ? .showMain : .restore
      return
    }
    guard let window else {
      quick = false
      home = nil
      return
    }
    guard quick, let saved = home else {
      quick = false
      if showMain { orderMain(window) }
      return
    }
    quick = false
    home = nil
    placing = true
    restoreStyle(window, saved)
    let keep = showMain || (saved.visible && !saved.miniaturized)
    window.setFrame(saved.frame, display: keep && window.isVisible)
    window.setFrameAutosaveName(saved.autosaveName)
    window.setFrame(saved.frame, display: keep && window.isVisible)
    placing = false
    refit(window)
    if showMain {
      orderMain(window)
      if saved.fullScreen { window.toggleFullScreen(nil) }
      previousApp = nil
      return
    }
    if saved.miniaturized {
      window.miniaturize(nil)
      return
    }
    if !saved.visible {
      let returnsFocus = window.isKeyWindow && NSApp.isActive
      window.orderOut(nil)
      returnFocus(returnsFocus)
      return
    }
    if saved.fullScreen { window.toggleFullScreen(nil) }
    if let previous = previousApp {
      previousApp = nil
      RunLoop.main.perform { _ = MainActor.assumeIsolated { previous.activate() } }
    }
  }

  /// Hide took the Dock icon. The mark stays up even when Show in Menu Bar is off.
  /// Only the window this controller owns: another window's close is not this one.
  @objc private func holdMenuBarIcon(_ note: Notification) {
    guard let hiding = note.object as? NSWindow, hiding === window else { return }
    holdsMenuBarIcon = true
    refreshStatusItem()
  }

  /// After the click that opened the window. Removing the status item inside
  /// its own action drops the click.
  @objc private func releaseMenuBarIcon() {
    holdsMenuBarIcon = false
    DispatchQueue.main.async { [weak self] in self?.refreshStatusItem() }
  }

  /// Whether the menu bar is showing the mark.
  var menuBarIconShown: Bool { statusItem != nil }

  /// The red button puts the window away. Done first, so it is put away at
  /// its own frame and showing it again brings that frame back.
  @objc private func windowWillHide(_ note: Notification) {
    guard let hiding = note.object as? NSWindow, hiding === window, quick, let saved = home else { return }
    quick = false
    home = nil
    placing = true
    restoreStyle(hiding, saved)
    hiding.setFrame(saved.frame, display: false)
    hiding.setFrameAutosaveName(saved.autosaveName)
    hiding.setFrame(saved.frame, display: false)
    placing = false
    refit(hiding)
  }

  private func orderMain(_ window: NSWindow) {
    AppPresence.returnToDock()
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func returnFocus(_ returns: Bool) {
    let previous = returns ? previousApp : nil
    previousApp = nil
    guard let previous else { return }
    RunLoop.main.perform { _ = MainActor.assumeIsolated { previous.activate() } }
  }

  /// The terminal measures the view. Laying the content out now is what
  /// tells it the frame just applied, quick or main.
  private func refit(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// Hung from the top of `screen` at the remembered size, or the default.
  private func place(_ window: NSWindow, on screen: NSScreen) {
    let frame = Self.frame(in: screen.visibleFrame, size: quickSize, minimum: window.minSize)
    let was = placing
    placing = true
    window.setFrame(frame, display: window.isVisible)
    placing = was
  }

  /// Forget a dragged size. The next show, and this one if it is summoned,
  /// is the full width of the display and its top third.
  func resetSize() {
    quickSize = nil
    defaults.removeObject(forKey: Self.widthKey)
    defaults.removeObject(forKey: Self.heightKey)
    guard quick, let window, window.isVisible, let screen = window.screen else { return }
    place(window, on: screen)
  }

  /// Dragged to another display while summoned: it hangs from that display's
  /// top, as it would have been shown there.
  @objc private func screenChanged() {
    guard quick, !placing, let window, window.isVisible, !window.inLiveResize,
      let screen = window.screen else { return }
    place(window, on: screen)
  }

  /// A drag while summoned ended: that is its size from now on, here and
  /// across launches. A frame set by code — the shortcut, a display change —
  /// is not a drag and leaves the memory alone.
  @objc private func resized() {
    guard quick, !placing, let window, window.isVisible, !window.inLiveResize else { return }
    remember(window.frame.size)
  }

  private func remember(_ size: NSSize) {
    guard size.width > 0, size.height > 0 else { return }
    quickSize = size
    defaults.set(Double(size.width), forKey: Self.widthKey)
    defaults.set(Double(size.height), forKey: Self.heightKey)
  }

  /// Close the summon and put the window back. Focus changes call this so
  /// they cannot open it.
  func hide() {
    guard quick || afterFullScreenExit != nil else { return }
    leaveQuick(showMain: false)
  }

  /// The display under `point`. A point on no display is none: the shortcut
  /// does not follow the frontmost window.
  static func screenIndex(of point: NSPoint, screens: [NSRect]) -> Int? {
    screens.firstIndex { NSMouseInRect(point, $0, false) }
  }

  private static func mouseScreen() -> NSScreen? {
    let point = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
  }

  /// Shorter than the document window, so a third of a laptop is allowed.
  static let minimumSize = NSSize(width: Chrome.windowMinWidth, height: 200)

  /// The overlay's frame on a display: hung from the top, centred. Full
  /// width and the top third until a size was dragged, then that size,
  /// clamped to the display and never below the window's minimum.
  static func frame(in visibleFrame: NSRect, size: NSSize?, minimum: NSSize) -> NSRect {
    let wanted = size ?? NSSize(width: visibleFrame.width, height: visibleFrame.height / 3)
    let width = min(visibleFrame.width, max(minimum.width, wanted.width))
    let height = min(visibleFrame.height, max(minimum.height, wanted.height))
    // Whole points. A fractional frame is handed back a point off, so the
    // window would not be the one just set.
    return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.maxY - height,
      width: width, height: height).integral
  }

  @objc private func resignedKey() {
    // Sheets and popovers stay with their terminal. A separate Tether
    // window (Settings, for example) must remain reachable above the overlay.
    DispatchQueue.main.async { [weak self] in
      self?.considerHiding(afterSheet: true)
    }
  }

  /// Focus left the overlay. A dialog asked here can take key a turn before
  /// it is attached, and the overlay is often not the active app. Neither
  /// puts the window back: the question was asked where the window is.
  private func considerHiding(afterSheet: Bool) {
    guard !showingStatusMenu, let window, window.isVisible,
      !window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
      !Self.questionOf(window) else { return }
    if afterSheet {
      DispatchQueue.main.async { [weak self] in self?.considerHiding(afterSheet: false) }
      return
    }
    if NSApp.isActive || autoHide { hide() }
  }

  /// A sheet or a child of any window (a dialog, a popover) is still this
  /// terminal. Checked for the app's key window, which may not be ours yet.
  private static func questionOf(_ window: NSWindow) -> Bool {
    guard let key = NSApp.keyWindow else { return false }
    if key.sheetParent != nil || key.parent != nil { return true }
    return window.sheets.contains { $0 === key }
  }

  /// Sent several times for every switch, Pinyin on or off included. Only a
  /// new ASCII-capable layout moves a shortcut to another key.
  @objc func keyboardChanged() {
    guard bindings.map(\.carbonKeyCode) != registeredCodes else { return }
    refreshHotKeys()
  }

  @objc private func statusPressed() {
    guard let event = NSApp.currentEvent,
      event.type == .rightMouseDown || event.modifierFlags.contains(.control)
    else {
      statusItemClicked()
      return
    }
    guard let statusItem, let button = statusItem.button else { return }
    showingStatusMenu = true
    statusItem.menu = statusMenu()
    defer {
      statusItem.menu = nil
      showingStatusMenu = false
    }
    button.performClick(nil)
  }

  /// Build at the time of the click: the shortcut can show or hide the
  /// overlay while the status item stays where it is.
  func statusMenu() -> NSMenu {
    let menu = NSMenu()
    let toggle = NSMenuItem(title: isShown ? "Return to Main Window" : "Show Main Window",
      action: #selector(statusItemClicked), keyEquivalent: "")
    toggle.target = self
    menu.addItem(toggle)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit Tether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.target = NSApp
    menu.addItem(quit)
    menu.autoenablesItems = false
    return menu
  }

  /// The menu bar opens the main window. The click takes key focus as it
  /// lands, so this cannot ask whether the window is still key.
  @objc func statusItemClicked() {
    showAsMainWindow()
  }

  /// The menu-bar mark. Hide keeps it while the Dock icon is gone, even when
  /// Show in Menu Bar is off: that mark is the way back.
  static func wantsMenuBarIcon(enabled: Bool, preference: Bool, holdingForHide: Bool, hasWindow: Bool) -> Bool {
    hasWindow && (holdingForHide || (enabled && preference))
  }

  private func refreshStatusItem() {
    guard Self.wantsMenuBarIcon(
      enabled: enabled, preference: showsMenuBarIcon, holdingForHide: holdsMenuBarIcon, hasWindow: canShow)
    else {
      if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
      statusItem = nil
      return
    }
    if statusItem == nil {
      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      statusItem?.button?.image = MenuBarMark.image
      statusItem?.button?.target = self
      statusItem?.button?.action = #selector(statusPressed)
      statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseDown])
    }
    let shortcut = bindings.map(\.label).joined(separator: " / ")
    statusItem?.button?.toolTip = shortcut.isEmpty ? "Show Main Window" : "Show Main Window (\(shortcut))"
  }

  private func refreshHotKeys() {
    for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
    hotKeys = []
    registeredCodes = []
    shortcutProblem = nil
    guard enabled, !recordingShortcut, canShow else { return }
    if eventHandler == nil {
      var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard result == noErr, id.signature == 0x54455448 else { return OSStatus(eventNotHandledErr) }
        // Return before touching the window. Activation from inside this
        // handler waits on the window server, and the server waits on the
        // handler — the window never comes back.
        MainActor.assumeIsolated {
          Unmanaged<QuickTerminalController>.fromOpaque(context).takeUnretainedValue()
            .scheduleToggleFromHotKey()
        }
        return noErr
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
      guard status == noErr else {
        shortcutProblem = "Could not install Quick Terminal hotkey handler (\(status))."
        return
      }
    }
    let codes = bindings.map(\.carbonKeyCode)
    for (index, binding) in bindings.enumerated() {
      guard let keyCode = codes[index] else {
        shortcutProblem = "\(binding.label) is unavailable on this keyboard layout. Choose another shortcut."
        continue
      }
      var ref: EventHotKeyRef?
      let id = EventHotKeyID(signature: 0x54455448, id: UInt32(index + 1))
      let status = RegisterEventHotKey(UInt32(keyCode), binding.carbonModifiers, id,
        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
      if status == noErr, let ref { hotKeys.append(ref) }
      else { shortcutProblem = "\(binding.label) could not be registered (\(status)). It may be used by another app. Choose another shortcut." }
    }
    registeredCodes = codes
  }

  /// Global notifications outlive the window this was attached to. A controller
  /// released without `stop` must not stay registered for them.
  deinit {
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
  }

  func stop() {
    for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
    hotKeys = []
    if let eventHandler { RemoveEventHandler(eventHandler) }
    eventHandler = nil
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
    listening = false
    if quick || afterFullScreenExit != nil { leaveQuick(showMain: false) }
    if let window { unobserve(window) }
    window = nil
    bindingsStore = nil
  }
}

extension QuickTerminalController {
  /// The window as the shortcut found it.
  fileprivate struct Home {
    var frame: NSRect
    var visible: Bool
    var miniaturized: Bool
    var fullScreen: Bool
    var collectionBehavior: NSWindow.CollectionBehavior
    var minSize: NSSize
    var contentMinSize: NSSize
    var animationBehavior: NSWindow.AnimationBehavior
    var autosaveName: String
  }

  fileprivate enum FullScreenFollowUp: Equatable {
    case presentQuick
    case restore
    case showMain
  }
}

/// The menu-bar mark, drawn from the app logo and used as a template so
/// the system tints it for the menu bar.
enum MenuBarMark {
  static let image: NSImage = make()

  private static func make() -> NSImage {
    let side: CGFloat = 18
    let mark = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      guard let logo = NSImage(named: "Logo") else { return false }
      let crop = opaqueBounds(of: logo) ?? NSRect(origin: .zero, size: logo.size)
      let fitted = aspectFit(crop.size, into: rect.insetBy(dx: 1, dy: 1))
      logo.draw(in: fitted, from: crop, operation: .sourceOver, fraction: 1)
      return true
    }
    guard NSImage(named: "Logo") != nil else {
      let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Tether") ?? mark
      symbol.isTemplate = true
      return symbol
    }
    mark.isTemplate = true
    mark.accessibilityDescription = "Tether"
    return mark
  }

  /// The logo's drawn shape, in its own point space, so the transparent
  /// margin does not shrink the mark.
  private static func opaqueBounds(of logo: NSImage) -> NSRect? {
    let pixels = 128
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0),
      let data = rep.bitmapData
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    logo.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let row = rep.bytesPerRow
    var minX = pixels, minY = pixels, maxX = -1, maxY = -1
    for y in 0..<pixels {
      for x in 0..<pixels where data[y * row + x * 4 + 3] > 24 {
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let scaleX = logo.size.width / CGFloat(pixels)
    let scaleY = logo.size.height / CGFloat(pixels)
    // The bitmap's first row is the top of what was drawn.
    return NSRect(
      x: CGFloat(minX) * scaleX,
      y: CGFloat(pixels - 1 - maxY) * scaleY,
      width: CGFloat(maxX - minX + 1) * scaleX,
      height: CGFloat(maxY - minY + 1) * scaleY)
  }

  private static func aspectFit(_ size: CGSize, into rect: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return rect }
    let scale = min(rect.width / size.width, rect.height / size.height)
    let width = size.width * scale
    let height = size.height * scale
    return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
  }
}

struct QuickTerminalSettings: View {
  @Bindable var controller: QuickTerminalController
  var bindings: KeyBindingStore?

  var body: some View {
    Section("Quick Terminal") {
      Toggle("Enable Quick Terminal", isOn: $controller.enabled)
      LabeledContent("Global Shortcut", value: bindings?.summary(for: WorkspaceAction.quickTerminal.command) ?? "Not set")
      Button("Change Shortcut…") { SettingsSectionPreference.show(.keyBindings) }
      Toggle("Hide When Switching Apps", isOn: $controller.autoHide)
        .disabled(!controller.enabled)
      Toggle("Show in Menu Bar", isOn: $controller.showsMenuBarIcon)
        .disabled(!controller.enabled)
      if let problem = controller.shortcutProblem {
        Text(problem).foregroundStyle(Theme.warning)
      }
      Button("Show / Hide Quick Terminal") { controller.toggle() }
        .disabled(!controller.enabled)
      Button("Reset Size") { controller.resetSize() }
        .disabled(!controller.enabled)
        .help("Full width, the top third of the screen")
    }
    Section("Window") {
      Toggle("Keep Window on Top", isOn: $controller.alwaysOnTop)
    }
  }
}
#endif
