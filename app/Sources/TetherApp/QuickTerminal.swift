#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import TetherUI

/// Presents the existing workspace as a hotkey terminal. Hiding the window
/// never closes a session; leaving this mode restores its ordinary geometry.
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
  @ObservationIgnored private var pendingShow = false
  @ObservationIgnored private var bindingsStore: KeyBindingStore?
  @ObservationIgnored private var bindings: [KeyBinding] = []
  @ObservationIgnored private var hotKeys: [EventHotKeyRef] = []
  @ObservationIgnored private var eventHandler: EventHandlerRef?
  @ObservationIgnored private var statusItem: NSStatusItem?
  @ObservationIgnored private var showingStatusMenu = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    enabled = defaults.object(forKey: "quickTerminal.enabled") as? Bool ?? true
    alwaysOnTop = defaults.bool(forKey: "window.alwaysOnTop")
    autoHide = defaults.object(forKey: "quickTerminal.autoHide") as? Bool ?? true
    showsMenuBarIcon = defaults.object(forKey: "quickTerminal.menuBarIcon") as? Bool ?? true
    super.init()
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

  func toggle() {
    guard enabled, let window else { return }
    if window.styleMask.contains(.fullScreen) {
      pendingShow = true
      window.toggleFullScreen(nil)
    } else if isQuick && window.isVisible && window.isKeyWindow {
      hide()
    } else {
      show()
    }
  }

  private func show() {
    guard let window else { return }
    if !isQuick {
      normalFrame = window.frame
      normalBehavior = window.collectionBehavior
      isQuick = true
    }
    let front = NSWorkspace.shared.frontmostApplication
    if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
    // The pointer chooses the display, including screens to the left or
    // above the primary display. visibleFrame respects the menu bar/notch.
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? window.screen ?? NSScreen.main
    if let screen {
      window.setFrame(Self.frame(in: screen.visibleFrame, minimumHeight: window.minSize.height), display: true)
    }
    window.level = .floating
    var behavior = window.collectionBehavior
    behavior.remove([.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone, .primary, .auxiliary])
    behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications])
    window.collectionBehavior = behavior
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  /// Kept separate from toggle so focus changes cannot accidentally reopen it.
  func hide() {
    guard isQuick, let window else { return }
    let returnsFocus = window.isKeyWindow && NSApp.isActive
    window.orderOut(nil)
    if returnsFocus { previousApp?.activate() }
    previousApp = nil
  }

  @objc func restore() {
    pendingShow = false
    guard isQuick, let window else { return }
    isQuick = false
    if let normalBehavior { window.collectionBehavior = normalBehavior }
    if let normalFrame { window.setFrame(normalFrame, display: true) }
    window.level = alwaysOnTop ? .floating : .normal
    self.normalFrame = nil
    self.normalBehavior = nil
    previousApp = nil
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  static func frame(in visibleFrame: NSRect, minimumHeight: CGFloat) -> NSRect {
    let height = min(visibleFrame.height, max(minimumHeight, visibleFrame.height / 2))
    return NSRect(x: visibleFrame.minX, y: visibleFrame.maxY - height,
      width: visibleFrame.width, height: height)
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

  @objc private func keyboardChanged() { refreshHotKeys() }

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
        MainActor.assumeIsolated {
          Unmanaged<QuickTerminalController>.fromOpaque(context).takeUnretainedValue().toggle()
        }
        return noErr
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
      guard status == noErr else {
        shortcutProblem = "Could not install Quick Terminal hotkey handler (\(status))."
        return
      }
    }
    for (index, binding) in bindings.enumerated() {
      guard let keyCode = binding.carbonKeyCode else {
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

/// Attaches only to the main scene, never a Settings window or a sheet.
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

struct QuickTerminalHost: NSViewRepresentable {
  let controller: QuickTerminalController
  let bindings: KeyBindingStore

  func makeNSView(context: Context) -> Hook { Hook(controller: controller) }
  func updateNSView(_ view: Hook, context: Context) { controller.useBindings(bindings) }
  static func dismantleNSView(_ view: Hook, coordinator: ()) { view.controller.stop() }

  final class Hook: NSView {
    let controller: QuickTerminalController
    init(controller: QuickTerminalController) {
      self.controller = controller
      super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { controller.attach(to: window) }
    }
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
