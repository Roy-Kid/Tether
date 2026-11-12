#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import TetherUI

/// The hotkey terminal: its own panel, summoned over whatever is in
/// front. The shortcut shows that panel on the display under the pointer —
/// key without making Tether the active app, on every Space, another
/// app's full-screen one on another display included. The workspace
/// window is left exactly as it was: summoning and hiding never move,
/// restyle, resize or full-screen-exit it, and Keep on Top remains the
/// main window's own setting. Closing the summon — shortcut, focus loss,
/// or a reveal of the main window — only hides the panel; sessions live
/// in the shared TabSet and are never closed here. The Dock and the menu
/// bar open the main window, not this panel; the menu-bar mark brings the
/// main window back. Hiding never closes a session.
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
  /// Keeps the main window above other apps' windows. The quick panel
  /// floats whatever this says: its level is its own, permanent one.
  var alwaysOnTop: Bool {
    didSet {
      defaults.set(alwaysOnTop, forKey: "window.alwaysOnTop")
      mainWindow?.level = alwaysOnTop ? .floating : .normal
    }
  }
  var autoHide: Bool {
    didSet { defaults.set(autoHide, forKey: "quickTerminal.autoHide") }
  }
  /// Where the panel appears on the display it shows on. The panel is
  /// the same floating, non-activating overlay in every mode; only the
  /// placement differs.
  var placement: QuickTerminalPlacement {
    didSet {
      defaults.set(placement.rawValue, forKey: Self.placementKey)
      // Each mode remembers its own dragged size, so switching between
      // a full-width and a side placement does not inherit a shape that
      // makes no sense there.
      quickSize = Self.storedSize(in: defaults, placement: placement)
      replaceShownPanel()
    }
  }
  /// The display the panel appears on: its stable CoreGraphics UUID, or
  /// nil to follow the pointer. A value that matches no attached display
  /// is kept — the panel falls back to the pointer's display and comes
  /// back to the chosen one when it reconnects.
  var displayID: String? {
    didSet {
      if let displayID { defaults.set(displayID, forKey: Self.displayKey) }
      else { defaults.removeObject(forKey: Self.displayKey) }
      replaceShownPanel()
    }
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

  /// The workspace window. It is read, never changed: only its `level`
  /// follows Keep on Top, and it is the target when the Dock or the menu
  /// bar asks for the main window.
  @ObservationIgnored private weak var mainWindow: NSWindow?
  /// The displays considered for placement; a test substitutes a fixed
  /// set to exercise removal and reconnection.
  @ObservationIgnored var placementDisplays: () -> [QuickDisplay] = { QuickDisplayCatalog.current() }
  /// What the panel's current frame was computed from
  /// (`QuickTerminalController.placeIfNeeded`). Never inferred from
  /// `panel.screen`: that is the window server's answer, not the
  /// placement's.
  @ObservationIgnored private var placedFor: FrameBasis?
  /// The quick terminal's own panel. Made once, owned here: hiding orders
  /// it out and showing brings it back, but it is never released, never
  /// closed, and its style mask, level and collection behavior are never
  /// touched after `init` (`QuickTerminalWindow`).
  @ObservationIgnored private(set) var panel: QuickTerminalWindow?
  /// How this panel is known to the shared TabSet's window arbitration
  /// (`TabSet.note`). The quick root reports the panel's shown/key state
  /// under this id; the panel never presents region dialogs
  /// (`TabSet.presentsDialogs`).
  @ObservationIgnored let panelID = UUID()
  @ObservationIgnored private let defaults: UserDefaults
  /// The app in front when the panel was summoned; key returns to it when
  /// the summon ends on its own. Read through a seam so a test can pose
  /// another app being in front.
  @ObservationIgnored private var previousApp: NSRunningApplication?
  /// Where key goes when the summon ends on its own. The real one
  /// activates the app the summon took key from; a test replaces it with
  /// a recorder rather than watching real activations.
  @ObservationIgnored var focusRestore: (@MainActor (NSRunningApplication) -> Void) = { $0.activate() }
  /// The app currently in front, read at summon time. Injected in tests.
  @ObservationIgnored var frontmostApplication: () -> NSRunningApplication? = {
    NSWorkspace.shared.frontmostApplication
  }
  /// Bumped by every summon and every explicit reveal of the main window:
  /// a focus restore an earlier hide scheduled is dropped when it fires
  /// after either, so it cannot steal key back.
  @ObservationIgnored private var focusGeneration = 0
  /// The summoned size as it was last dragged, for the current
  /// placement. Nil until a drag, or after Reset: the placement's
  /// default. The top placement keeps the keys it has always had.
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

  static let placementKey = "quickTerminal.placement"
  static let displayKey = "quickTerminal.display"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    enabled = defaults.object(forKey: "quickTerminal.enabled") as? Bool ?? true
    alwaysOnTop = defaults.bool(forKey: "window.alwaysOnTop")
    autoHide = defaults.object(forKey: "quickTerminal.autoHide") as? Bool ?? true
    showsMenuBarIcon = defaults.object(forKey: "quickTerminal.menuBarIcon") as? Bool ?? true
    let storedPlacement = QuickTerminalPlacement(
      rawValue: defaults.string(forKey: Self.placementKey) ?? "") ?? .top
    placement = storedPlacement
    displayID = defaults.string(forKey: Self.displayKey)
    quickSize = Self.storedSize(in: defaults, placement: storedPlacement)
    super.init()
  }

  private static let widthKey = "quickTerminal.width"
  private static let heightKey = "quickTerminal.height"

  private static func sizeKeys(for placement: QuickTerminalPlacement) -> (String, String) {
    guard placement != .top else { return (widthKey, heightKey) }
    return ("\(widthKey).\(placement.rawValue)", "\(heightKey).\(placement.rawValue)")
  }

  private static func storedSize(in defaults: UserDefaults, placement: QuickTerminalPlacement) -> NSSize? {
    let keys = sizeKeys(for: placement)
    let width = defaults.double(forKey: keys.0)
    let height = defaults.double(forKey: keys.1)
    guard width > 0, height > 0 else { return nil }
    return NSSize(width: width, height: height)
  }

  /// Whether the shortcut has a panel to summon.
  private var canShow: Bool { panel != nil }

  /// Whether the panel is up. Derived from the panel itself, so an
  /// order-out that did not come from this controller cannot leave the
  /// state claiming it is shown.
  var isQuick: Bool { isShown }

  /// Whether the panel is up on the pointer's display.
  var isShown: Bool { panel?.isVisible == true }

  /// The workspace window. Its frame, style, collection behavior and
  /// full-screen state are never touched — only `level` follows Keep on
  /// Top, once, here. Attaching again is idempotent: a controller that
  /// was stopped and re-attached to the same window starts listening
  /// again instead of bailing out early.
  func attach(to window: NSWindow) {
    mainWindow = window
    window.level = alwaysOnTop ? .floating : .normal
    startListening()
  }

  /// The panel this controller summons. Made once and owned here; the
  /// shortcut shows and hides it, and dismissal is hide-only — the panel
  /// owns no sessions and closing it is not a thing that happens.
  func attach(panel: QuickTerminalWindow) {
    guard self.panel !== panel else { return }
    unobservePanel()
    self.panel = panel
    for name in Self.panelNotes {
      NotificationCenter.default.addObserver(self, selector: selector(for: name), name: name, object: panel)
    }
    refreshHotKeys()
    refreshStatusItem()
  }

  private static let panelNotes: [Notification.Name] = [
    NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
    NSWindow.didEndLiveResizeNotification,
  ]

  private func selector(for name: Notification.Name) -> Selector {
    switch name {
    case NSWindow.didChangeScreenNotification: #selector(screenChanged)
    case NSWindow.didEndLiveResizeNotification: #selector(resized)
    default: #selector(resignedKey)
    }
  }

  private func unobservePanel() {
    guard let panel else { return }
    for name in Self.panelNotes {
      NotificationCenter.default.removeObserver(self, name: name, object: panel)
    }
  }

  private var listening = false

  private func startListening() {
    if !listening {
      listening = true
      NotificationCenter.default.addObserver(self, selector: #selector(resignedKey),
        name: NSApplication.didResignActiveNotification, object: NSApp)
      NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
        name: NSApplication.didChangeScreenParametersNotification, object: nil)
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
    guard let panel else { return }
    if isShown && panel.isKeyWindow && panel.isOnActiveSpace {
      hide()
    } else {
      show()
    }
  }

  /// The Dock, the menu bar, and any reopen: the main window, at its own
  /// frame. The panel steps aside first; it is not the main window and it
  /// never moves it. The reveal decides where key goes itself, so a focus
  /// restore an earlier hide scheduled is dropped, not deferred into a
  /// fight over key.
  func showAsMainWindow() {
    focusGeneration += 1
    panel?.orderOut(nil)
    guard let mainWindow else { return }
    orderMain(mainWindow)
  }

  /// Summon: onto the chosen display, key without activating. The main
  /// window is not asked to move, restyle or leave full screen — the panel
  /// goes over it, on whatever Space it is on.
  private func show() {
    guard enabled, let panel else { return }
    // A newer summon supersedes any restore an earlier hide scheduled.
    focusGeneration += 1
    let front = frontmostApplication()
    if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      previousApp = front
    } else {
      previousApp = nil
    }
    // Showing on a Space that is no longer in front: come here rather than
    // send the person back there. Re-framed while still there, a window is
    // put on the pointer's display instead of the one asked for.
    if panel.isVisible && !panel.isOnActiveSpace { panel.orderOut(nil) }
    placing = true
    let placed = placeIfNeeded()
    panel.orderFrontRegardless()
    // Ordering a hidden window on screen can hand it back narrower than it
    // was set — measured with Stage Manager on: 2560 points asked for, 2316
    // given, whatever the content view. A frame set while it is up stays.
    if placed { placeIfNeeded(force: true) }
    placing = false
    panel.makeKey()
    // The grid follows the view's bounds. A frame set here does not otherwise
    // reach it, and the shell keeps the size it had.
    refit(panel)
  }

  /// Which display the panel shows on: the fixed choice when that display
  /// is attached, the pointer's display otherwise, then the main or any
  /// display. Nil only when there are no displays at all — the panel
  /// shows where it was, rather than not at all.
  private func placementTarget() -> NSScreen? {
    let displays = placementDisplays()
    let pointer = Self.mouseScreen()
    let wanted = QuickDisplayChoice.target(
      fixedID: displayID,
      pointerID: pointer.flatMap { QuickDisplayCatalog.id(for: $0) },
      displays: displays)
    if let wanted, let screen = QuickDisplayCatalog.screen(withID: wanted) { return screen }
    return pointer ?? panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
  }

  private func frameBasis(for screen: NSScreen) -> FrameBasis {
    FrameBasis(placement: placement, targetID: QuickDisplayCatalog.id(for: screen))
  }

  /// Hang the panel on its target when the placement or the display
  /// changed — or unconditionally, for an edge placement, which snaps to
  /// its edge. A floating panel keeps the position it was dragged to
  /// while the basis is unchanged and the frame still fits the display.
  /// Works on a hidden panel too: the frame is set before the panel is
  /// ordered in. Returns whether it placed.
  @discardableResult
  private func placeIfNeeded(force: Bool = false) -> Bool {
    guard let panel else { return false }
    // No displays: leave the frame alone, whatever it is.
    guard let screen = placementTarget() else { return false }
    let basis = frameBasis(for: screen)
    if !force, Self.shouldKeepFrame(
      current: placedFor, requested: basis, frame: panel.frame, visibleFrame: screen.visibleFrame) {
      return false
    }
    place(panel, on: screen)
    placedFor = basis
    return true
  }

  /// A placement or display change re-hangs a shown panel on its new
  /// target, in every mode — the floating placement honors it too,
  /// unless the basis did not change at all.
  private func replaceShownPanel() {
    placeIfNeeded()
  }

  /// Dismiss: the panel orders out and nothing else changes. No session is
  /// closed — the panel owns none — and the workspace window is untouched.
  func hide() {
    guard let panel, panel.isVisible else { return }
    let wasKey = panel.isKeyWindow
    panel.orderOut(nil)
    returnFocus(wasKey)
  }

  private func orderMain(_ window: NSWindow) {
    AppPresence.returnToDock()
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Key goes back to wherever the summon took it from: the app that was
  /// in front, or — Tether was in front — the workspace window, made key
  /// again without an activation it does not need. A restore waits a turn
  /// and is dropped if a summon or a reveal of the main window superseded
  /// it meanwhile: it must never steal key back.
  private func returnFocus(_ returns: Bool) {
    if returns, let previous = previousApp {
      previousApp = nil
      let generation = focusGeneration
      let restore = focusRestore
      RunLoop.main.perform { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.focusGeneration == generation else { return }
          restore(previous)
        }
      }
      return
    }
    previousApp = nil
    // Tether was in front when the panel was summoned: its window takes
    // key back, without an activation it does not need.
    guard returns, let mainWindow, mainWindow.isVisible, !mainWindow.isMiniaturized else { return }
    mainWindow.makeKey()
  }

  /// The terminal measures the view. Laying the content out now is what
  /// tells it the frame just applied.
  private func refit(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// Hung from the top of the display at the placement's edge, at the
  /// remembered size or the default.
  private func place(_ window: NSWindow, on screen: NSScreen) {
    let frame = Self.frame(
      in: screen.visibleFrame, size: quickSize, minimum: window.minSize, placement: placement)
    let was = placing
    placing = true
    window.setFrame(frame, display: window.isVisible)
    placing = was
  }

  /// Forget the dragged size for the current placement. A shown panel
  /// takes the placement's default shape again; a hidden one does so on
  /// its next summon.
  func resetSize() {
    quickSize = nil
    let keys = Self.sizeKeys(for: placement)
    defaults.removeObject(forKey: keys.0)
    defaults.removeObject(forKey: keys.1)
    placedFor = nil
    placeIfNeeded(force: true)
  }

  /// Displays changed — added, removed, resized. A shown panel re-hangs
  /// on its target: a fixed choice that vanished falls back, one that
  /// came back wins again (the basis moved either way); a floating panel
  /// whose frame no longer fits the visible frame is pulled back inside
  /// it. Nothing happens with no displays.
  @objc private func screensChanged() {
    guard let panel, panel.isVisible else { return }
    guard let screen = placementTarget() else { return }
    let basis = frameBasis(for: screen)
    guard !Self.shouldKeepFrame(
      current: placedFor, requested: basis, frame: panel.frame, visibleFrame: screen.visibleFrame)
    else { return }
    place(panel, on: screen)
    placedFor = basis
  }

  /// Dragged to another display while summoned: an edge placement hangs
  /// from that display's corresponding edge, as it would have been shown
  /// there. The floating placement is never snapped; the basis follows
  /// the screen it is on, so a later summon keeps the dragged position
  /// only while the target resolves to the same display.
  @objc private func screenChanged() {
    guard !placing, let panel, panel.isVisible, !panel.inLiveResize, let screen = panel.screen else { return }
    if case .floating = placement {
      placedFor = frameBasis(for: screen)
      return
    }
    place(panel, on: screen)
    placedFor = frameBasis(for: screen)
  }

  /// A drag while summoned ended: that is its size from now on, here and
  /// across launches, remembered for the current placement alone. A
  /// frame set by code — the shortcut, a display change — is not a drag
  /// and leaves the memory alone.
  @objc private func resized() {
    guard !placing, let panel, panel.isVisible, !panel.inLiveResize else { return }
    remember(panel.frame.size)
  }

  private func remember(_ size: NSSize) {
    guard size.width > 0, size.height > 0 else { return }
    quickSize = size
    let keys = Self.sizeKeys(for: placement)
    defaults.set(Double(size.width), forKey: keys.0)
    defaults.set(Double(size.height), forKey: keys.1)
  }

  /// Focus left the panel — a click on the workspace window or Settings,
  /// or another app coming forward. Hiding orders only the panel out; any
  /// question the main window asked keeps its own window.
  @objc private func resignedKey() {
    DispatchQueue.main.async { [weak self] in
      self?.considerHiding()
    }
  }

  private func considerHiding() {
    guard !showingStatusMenu, let panel, panel.isVisible,
      !panel.isKeyWindow, NSApp.modalWindow == nil else { return }
    if NSApp.isActive || autoHide { hide() }
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

  /// The overlay's frame on a display: hung from the top at the
  /// remembered size, or the default — full width and the top third
  /// until a size was dragged (`resetSize` forgets it). Whole points: a
  /// fractional frame is handed back a point off, so the window would
  /// not be the one just set.
  static func frame(in visibleFrame: NSRect, size: NSSize?, minimum: NSSize) -> NSRect {
    Self.frame(in: visibleFrame, size: size, minimum: minimum, placement: .top)
  }

  /// Hide took the Dock icon. The mark stays up even when Show in Menu Bar is off.
  @objc private func holdMenuBarIcon(_ note: Notification) {
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
  /// lands, so this cannot ask whether the panel is still key.
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

  /// Global notifications outlive the panel this was attached to. A controller
  /// released without `stop` must not stay registered for them.
  deinit {
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
  }

  /// Teardown: hotkeys and the event handler are unregistered, the
  /// menu-bar mark comes down, and the panel orders out — not released;
  /// its lifetime is the app's, and hiding it never closes a session.
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
    panel?.orderOut(nil)
    bindingsStore = nil
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
  /// The displays attached now, refreshed when the hardware changes.
  @State private var displays: [QuickDisplay] = QuickDisplayCatalog.current()

  var body: some View {
    Section("Quick Terminal") {
      Toggle("Enable Quick Terminal", isOn: $controller.enabled)
      LabeledContent("Global Shortcut", value: bindings?.summary(for: WorkspaceAction.quickTerminal.command) ?? "Not set")
      Button("Change Shortcut…") { SettingsSectionPreference.show(.keyBindings) }
      Picker("Placement", selection: $controller.placement) {
        ForEach(QuickTerminalPlacement.allCases, id: \.self) { placement in
          Text(placement.title).tag(placement)
        }
      }
      Picker("Display", selection: $controller.displayID) {
        Text("Follow the Pointer").tag(String?.none)
        if let missing = controller.displayID,
          !displays.contains(where: { $0.id == missing }) {
          // The display is not attached. The choice stays — the panel
          // shows on the fallback display until it comes back — and the
          // picker keeps a valid tag for it meanwhile.
          Text("Unavailable Display").tag(String?.some(missing))
        }
        ForEach(displays, id: \.id) { display in
          Text(display.name).tag(String?.some(display.id))
        }
      }
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
        .help("This placement's default size")
    }
    Section("Window") {
      Toggle("Keep Window on Top", isOn: $controller.alwaysOnTop)
    }
    .onReceive(NotificationCenter.default.publisher(
      for: NSApplication.didChangeScreenParametersNotification)) { _ in
      displays = QuickDisplayCatalog.current()
    }
  }
}
#endif
