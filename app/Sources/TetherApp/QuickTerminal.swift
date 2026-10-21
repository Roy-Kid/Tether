#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import TetherUI

/// Presents the existing workspace as a hotkey terminal: the same window,
/// shown as an overlay. A non-activating panel is key without making this
/// the active app, so the app in front stays there and the window can join
/// any Space — another app's full-screen one on another display included —
/// which no activating window can (`WorkspaceWindow`). Hiding it never
/// closes a session; leaving this mode restores its ordinary geometry, and
/// the Dock leaves it (`reopen`): the shortcut means the overlay, the Dock
/// the ordinary window. The overlay's size is its own (`quickSize`): dragged
/// once, it comes back that size, while the ordinary window's frame stays
/// what its autosave remembers.
@MainActor @Observable
final class QuickTerminalController: NSObject {
  var enabled: Bool {
    didSet {
      defaults.set(enabled, forKey: "quickTerminal.enabled")
      if !enabled { restore() }
      refreshHotKeys()
      refreshStatusItem()
    }
  }
  var alwaysOnTop: Bool {
    didSet {
      defaults.set(alwaysOnTop, forKey: "window.alwaysOnTop")
      window?.level = isQuick || alwaysOnTop ? .floating : .normal
    }
  }
  var autoHide: Bool {
    didSet { defaults.set(autoHide, forKey: "quickTerminal.autoHide") }
  }
  /// The menu-bar mark. Off, and the shortcut still works.
  var showsMenuBarIcon: Bool {
    didSet {
      defaults.set(showsMenuBarIcon, forKey: "quickTerminal.menuBarIcon")
      refreshStatusItem()
    }
  }
  var recordingShortcut = false {
    didSet { refreshHotKeys() }
  }
  private(set) var isQuick = false
  private(set) var shortcutProblem: String?

  @ObservationIgnored private weak var window: NSWindow?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var normalFrame: NSRect?
  @ObservationIgnored private var normalBehavior: NSWindow.CollectionBehavior?
  @ObservationIgnored private var previousApp: NSRunningApplication?
  /// What the window animated with before quick mode. Ordering out with the
  /// default animation and ordering forward before it finishes waits on the
  /// window server, which is waiting for this thread.
  @ObservationIgnored private var normalAnimation: NSWindow.AnimationBehavior?
  /// Where the window remembers its frame. Not while quick: the overlay's
  /// frame is not what the next launch should open at; its size is kept
  /// apart, in `quickSize`.
  @ObservationIgnored private var normalAutosaveName: NSWindow.FrameAutosaveName?
  /// The overlay's size as it was last dragged, kept apart from the
  /// ordinary window's frame so each comes back as it was left. Nil until
  /// a drag: a display's top half.
  @ObservationIgnored private var quickSize: NSSize?
  @ObservationIgnored private var pendingShow = false
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

  func attach(to window: NSWindow) {
    guard self.window !== window else { return }
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
    self.window = window
    window.level = alwaysOnTop ? .floating : .normal
    NotificationCenter.default.addObserver(self, selector: #selector(resignedKey),
      name: NSWindow.didResignKeyNotification, object: window)
    NotificationCenter.default.addObserver(self, selector: #selector(exitedFullScreen),
      name: NSWindow.didExitFullScreenNotification, object: window)
    NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
      name: NSWindow.didChangeScreenNotification, object: window)
    NotificationCenter.default.addObserver(self, selector: #selector(resized),
      name: NSWindow.didEndLiveResizeNotification, object: window)
    NotificationCenter.default.addObserver(self, selector: #selector(resignedKey),
      name: NSApplication.didResignActiveNotification, object: NSApp)
    DistributedNotificationCenter.default().addObserver(self, selector: #selector(keyboardChanged),
      name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
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
    guard enabled, let window else { return }
    if window.styleMask.contains(.fullScreen) {
      pendingShow = true
      window.toggleFullScreen(nil)
    } else if isQuick && window.isVisible && window.isKeyWindow && window.isOnActiveSpace {
      hide()
    } else {
      show()
    }
  }

  /// Shown on every Space, a full-screen one included. An overlay is not
  /// a full-screen window of its own.
  private static let quickSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

  private func applyQuickBehavior(to window: NSWindow) {
    var behavior = window.collectionBehavior
    behavior.remove([.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone, .primary, .auxiliary])
    behavior.formUnion(Self.quickSpaces)
    window.collectionBehavior = behavior
  }

  private func removeQuickBehavior(from window: NSWindow) {
    var behavior = window.collectionBehavior
    behavior.remove(Self.quickSpaces)
    window.collectionBehavior = behavior
  }

  private func suspendAnimation(on window: NSWindow) {
    if normalAnimation == nil { normalAnimation = window.animationBehavior }
    window.animationBehavior = .none
  }

  private func show() {
    guard let window else { return }
    if !isQuick {
      normalFrame = window.frame
      normalBehavior = window.collectionBehavior
      normalAutosaveName = window.frameAutosaveName
      window.setFrameAutosaveName("")
      isQuick = true
    }
    let front = NSWorkspace.shared.frontmostApplication
    if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
    // The display being worked on: the one holding the frontmost app's
    // window. The pointer can rest on another display for hours, and is
    // only asked when no window says. visibleFrame respects the menu bar.
    let screen = Self.focusedScreen()
      ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? window.screen ?? NSScreen.main
    suspendAnimation(on: window)
    if window.isMiniaturized { window.deminiaturize(nil) }
    // Showing on a Space that is no longer in front: come here rather than
    // send the person back there. Re-framed while still there, a window is
    // put on the pointer's display instead of the one asked for.
    if window.isVisible && !window.isOnActiveSpace { window.orderOut(nil) }
    // Key without activating: the app in front keeps its place and its
    // menu bar, and the overlay comes up wherever it is asked to.
    (window as? NSPanel)?.styleMask.insert(.nonactivatingPanel)
    window.level = .floating
    applyQuickBehavior(to: window)
    let frame = screen.map { Self.frame(in: $0.visibleFrame, size: quickSize, minimum: window.minSize) }
    if let frame { window.setFrame(frame, display: window.isVisible) }
    window.orderFrontRegardless()
    // Ordering a hidden window on screen can hand it back narrower than it
    // was set — measured with Stage Manager on: 2560 points asked for, 2316
    // given, whatever the content view. A frame set while it is up stays.
    if let frame, window.frame != frame { window.setFrame(frame, display: true) }
    window.makeKey()
  }

  /// Dragged to another display: it hangs from that display's top, as it
  /// would have been shown there.
  @objc private func screenChanged() {
    guard isQuick, let window, window.isVisible, let screen = window.screen else { return }
    let frame = Self.frame(in: screen.visibleFrame, size: quickSize, minimum: window.minSize)
    guard window.frame != frame else { return }
    window.setFrame(frame, display: true)
  }

  /// A drag on the overlay ended: that is its size from now on, here and
  /// across launches. A frame set by code — `show`, a display change — is
  /// not a drag and leaves the memory alone.
  @objc private func resized() {
    guard isQuick, let window, window.isVisible else { return }
    let size = window.frame.size
    quickSize = size
    defaults.set(size.width, forKey: Self.widthKey)
    defaults.set(size.height, forKey: Self.heightKey)
  }

  /// Kept separate from toggle so focus changes cannot accidentally reopen it.
  func hide() {
    guard isQuick, let window else { return }
    let returnsFocus = window.isKeyWindow && NSApp.isActive
    suspendAnimation(on: window)
    removeQuickBehavior(from: window)
    window.orderOut(nil)
    let previous = returnsFocus ? previousApp : nil
    previousApp = nil
    if let previous {
      RunLoop.main.perform {
        _ = MainActor.assumeIsolated { previous.activate() }
      }
    }
  }

  /// The Dock asked for the window (`applicationShouldHandleReopen`). How
  /// the window is summoned decides how it shows: the shortcut and the menu
  /// bar mean the overlay, the Dock means the ordinary window. So an
  /// overlay — hidden, or still up — comes back ordinary; left quick, it
  /// would come back as the overlay for good, floating, which Stage Manager
  /// and Mission Control never list. False when the window was not quick,
  /// and the Dock's usual reveal is the answer.
  @discardableResult
  func reopen() -> Bool {
    guard isQuick else { return false }
    restore()
    return true
  }

  @objc func restore() {
    pendingShow = false
    guard isQuick, let window else { return }
    isQuick = false
    let hidden = !window.isVisible
    (window as? NSPanel)?.styleMask.remove(.nonactivatingPanel)
    if let normalBehavior { window.collectionBehavior = normalBehavior }
    if let normalFrame { window.setFrame(normalFrame, display: !hidden) }
    window.level = alwaysOnTop ? .floating : .normal
    if let normalAnimation { window.animationBehavior = normalAnimation }
    if let normalAutosaveName, !normalAutosaveName.isEmpty { window.setFrameAutosaveName(normalAutosaveName) }
    self.normalFrame = nil
    self.normalBehavior = nil
    self.normalAnimation = nil
    self.normalAutosaveName = nil
    previousApp = nil
    if hidden { window.orderFrontRegardless() }
    // An ordinary window again, and asked for by the person: in front
    // regardless. `activate()` only asks, and the app in front keeps it.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  /// The display holding the frontmost app's front window. Another app's
  /// windows are not ours to ask, so the window server's list answers.
  private static func focusedScreen() -> NSScreen? {
    guard let front = NSWorkspace.shared.frontmostApplication,
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return nil }
    let pid = front.processIdentifier
    let ordinary = windows.lazy
      .filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0 }
      .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:)) }
    let screens = NSScreen.screens
    return screenIndex(holding: Array(ordinary), screens: screens.map(\.frame)).map { screens[$0] }
  }

  /// Which of `screens` holds the frontmost of `windows`, listed front to
  /// back as the window server gives them: from the primary display's
  /// top-left corner, y down. One off every display is passed over: a
  /// full-screen app's toolbar waits just above its display while hidden.
  static func screenIndex(holding windows: [CGRect], screens: [NSRect]) -> Int? {
    guard let primary = screens.first else { return nil }
    for bounds in windows {
      let center = NSPoint(x: bounds.midX, y: primary.maxY - bounds.midY)
      if let index = screens.firstIndex(where: { NSMouseInRect(center, $0, false) }) { return index }
    }
    return nil
  }

  /// The overlay's frame on a display: hung from the top, centred. Full
  /// width and half the height until a size was dragged, then that size,
  /// clamped to the display and never below the window's minimum.
  static func frame(in visibleFrame: NSRect, size: NSSize?, minimum: NSSize) -> NSRect {
    let wanted = size ?? NSSize(width: visibleFrame.width, height: visibleFrame.height / 2)
    let width = min(visibleFrame.width, max(minimum.width, wanted.width))
    let height = min(visibleFrame.height, max(minimum.height, wanted.height))
    return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.maxY - height,
      width: width, height: height)
  }

  @objc private func resignedKey() {
    // Sheets and popovers stay with their terminal. A separate Tether
    // window (Settings, for example) must remain reachable above the overlay.
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.showingStatusMenu, self.isQuick, let window = self.window,
        !window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
      if NSApp.isActive {
        guard let key = NSApp.keyWindow, key.sheetParent == nil, key.parent == nil else { return }
        self.hide()
      } else if self.autoHide {
        self.hide()
      }
    }
  }

  @objc private func exitedFullScreen() {
    guard pendingShow else { return }
    pendingShow = false
    show()
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

  /// Build at the time of the click: visibility and quick mode can change
  /// through the global shortcut while the status item remains in place.
  func statusMenu() -> NSMenu {
    let menu = NSMenu()
    let visible = isQuick && window?.isVisible == true
    let toggle = NSMenuItem(title: visible ? "Hide Quick Terminal" : "Show Quick Terminal",
      action: #selector(statusItemClicked), keyEquivalent: "")
    toggle.target = self
    menu.addItem(toggle)
    let restore = NSMenuItem(title: "Restore Window", action: #selector(QuickTerminalController.restore), keyEquivalent: "")
    restore.target = self
    restore.isEnabled = isQuick
    menu.addItem(restore)
    menu.addItem(.separator())
    let close = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
    close.target = window
    close.isEnabled = window?.isVisible == true
    menu.addItem(close)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit Tether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.target = NSApp
    menu.addItem(quit)
    menu.autoenablesItems = false
    return menu
  }

  /// One click opens the quick terminal, the next closes it. The menu bar
  /// takes key focus as the click lands, so this cannot ask whether the
  /// window is still key — that would open it again instead of closing it.
  @objc func statusItemClicked() {
    guard enabled, let window else { return }
    if isQuick && window.isVisible {
      hide()
    } else {
      show()
    }
  }

  private func refreshStatusItem() {
    guard enabled, showsMenuBarIcon, window != nil else {
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
    statusItem?.button?.toolTip = shortcut.isEmpty ? "Quick Terminal" : "Quick Terminal (\(shortcut))"
  }

  private func refreshHotKeys() {
    for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
    hotKeys = []
    registeredCodes = []
    shortcutProblem = nil
    guard enabled, !recordingShortcut, window != nil else { return }
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

  func stop() {
    for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
    hotKeys = []
    if let eventHandler { RemoveEventHandler(eventHandler) }
    eventHandler = nil
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
    window = nil
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
      if controller.isQuick {
        Button("Return to Normal Window") { controller.restore() }
      }
    }
    Section("Window") {
      Toggle("Keep Window on Top", isOn: $controller.alwaysOnTop)
    }
  }
}
#endif
