#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import TetherPluginKit

/// A plugin panel stays alive while its permission sheet owns the keyboard.
/// A transient system popover would close and cancel that same request.
struct PluginPanelPopover: NSViewRepresentable {
  @Binding var isPresented: Bool
  var pluginID: String?
  let workspace: (any PluginWorkspace)?
  var defaults: UserDefaults = .standard

  func makeNSView(context: Context) -> Anchor { Anchor() }
  func updateNSView(_ view: Anchor, context: Context) {
    view.dismissed = { isPresented = false }
    view.presented = isPresented
    view.pluginID = pluginID
    view.defaults = defaults
    view.workspace = workspace
    view.updatePresentation()
  }
  static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }

  final class Anchor: NSView, NSPopoverDelegate {
    /// Wide enough for a job name on its own line, until a person drags a size.
    static let contentWidth: CGFloat = 460
    static let minimumWidth: CGFloat = 280
    static let maximumWidth: CGFloat = 720
    static let minimumHeight: CGFloat = 140
    static let maximumHeight: CGFloat = 720
    static let initialHeight: CGFloat = 240
    let popover = NSPopover()
    var presented = false
    var pluginID: String?
    var defaults = UserDefaults.standard
    var workspace: (any PluginWorkspace)?
    var dismissed: (() -> Void)?
    /// Set once a person has dragged the panel. Content fitting then leaves it alone.
    private var chosen = false
    private var dragOrigin: NSSize?
    private var monitor: Any?
    private var fitting: Task<Void, Never>?
    private var grip: CornerGrip?

    override init(frame: NSRect) {
      super.init(frame: frame)
      popover.behavior = .applicationDefined
      popover.animates = false
      popover.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { stop() } else { updatePresentation() }
    }

    func updatePresentation() {
      guard presented, let workspace, window != nil else {
        if popover.isShown { popover.performClose(nil) }
        return
      }
      guard !popover.isShown else { return }
      let hosting = NSHostingController(rootView: workspace.content())
      // The page reports its own height. SwiftUI must not pin a preferred size.
      hosting.sizingOptions = []
      let container = NSViewController()
      let page = hosting.view
      page.translatesAutoresizingMaskIntoConstraints = false
      container.view = NSView()
      container.view.addSubview(page)
      container.addChild(hosting)
      NSLayoutConstraint.activate([
        page.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
        page.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
        page.topAnchor.constraint(equalTo: container.view.topAnchor),
        page.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
      ])
      popover.contentViewController = container
      let remembered = pluginID.flatMap { Self.storedSize(pluginID: $0, defaults: defaults) }
      chosen = remembered != nil
      popover.contentSize = remembered ?? NSSize(width: Self.contentWidth, height: Self.initialHeight)
      popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
      if !chosen { beginFitting() }
      installGrip()
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
        [weak self] event in
        guard let self else { return event }
        return self.route(event)
      }
    }

    /// Poll the installed page. `body` is content-sized, so a tall viewport can still shrink.
    private func beginFitting() {
      fitting?.cancel()
      fitting = Task { @MainActor [weak self] in
        while let self, !Task.isCancelled {
          await self.fitToContent()
          try? await Task.sleep(for: .milliseconds(250))
        }
      }
    }

    private func fitToContent() async {
      guard !chosen, popover.isShown, let root = popover.contentViewController?.view,
        let web = Self.webView(in: root) else { return }
      let value = try? await web.evaluateJavaScript(
        "Math.ceil(document.body.getBoundingClientRect().height)")
      guard !Task.isCancelled, !chosen, let measured = Self.points(value) else { return }
      let height = min(Self.maximumHeight, max(Self.minimumHeight, measured))
      let size = NSSize(width: Self.contentWidth, height: height)
      guard abs(popover.contentSize.height - size.height) > 0.5
        || abs(popover.contentSize.width - size.width) > 0.5 else { return }
      popover.contentSize = size
    }

    /// The size this plugin's panel opens at, after a drag. Absent until then.
    static func storedSize(pluginID: String, defaults: UserDefaults) -> NSSize? {
      guard let box = defaults.dictionary(forKey: Self.key(pluginID)),
        let width = (box["width"] as? NSNumber)?.doubleValue,
        let height = (box["height"] as? NSNumber)?.doubleValue,
        width.isFinite, height.isFinite
      else { return nil }
      return clamp(NSSize(width: width, height: height))
    }

    static func clamp(_ size: NSSize) -> NSSize {
      NSSize(
        width: min(max(size.width, minimumWidth), maximumWidth),
        height: min(max(size.height, minimumHeight), maximumHeight))
    }

    /// Applies a drag. `commit` writes it, so the next open is this size.
    func apply(_ size: NSSize, commit: Bool) {
      fitting?.cancel()
      fitting = nil
      chosen = true
      popover.contentSize = Self.clamp(size)
      guard commit, let pluginID else { return }
      let size = popover.contentSize
      defaults.set(
        ["width": Double(size.width), "height": Double(size.height)], forKey: Self.key(pluginID))
    }

    private static func key(_ pluginID: String) -> String { "plugin.panel.size.\(pluginID)" }

    /// The corner away from the anchor. The panel sits above the status row,
    /// so this edge is the one a drag grows.
    private func installGrip() {
      guard grip == nil, let content = popover.contentViewController?.view else { return }
      let grip = CornerGrip(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
      grip.toolTip = "Resize"
      grip.setAccessibilityLabel("Resize")
      grip.onResize = { [weak self] delta, ended in
        guard let self else { return }
        if self.dragOrigin == nil { self.dragOrigin = self.popover.contentSize }
        let origin = self.dragOrigin ?? self.popover.contentSize
        self.apply(
          NSSize(width: origin.width + delta.width, height: origin.height + delta.height),
          commit: ended)
        if ended { self.dragOrigin = nil }
      }
      grip.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(grip)
      NSLayoutConstraint.activate([
        grip.topAnchor.constraint(equalTo: content.topAnchor, constant: 2),
        grip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
        grip.widthAnchor.constraint(equalToConstant: 18),
        grip.heightAnchor.constraint(equalToConstant: 18),
      ])
      self.grip = grip
    }

    private static func points(_ value: Any?) -> CGFloat? {
      let number: Double?
      if let value = value as? Double { number = value }
      else if let value = value as? Int { number = Double(value) }
      else if let value = value as? NSNumber { number = value.doubleValue }
      else { number = nil }
      guard let number, number.isFinite, number > 0 else { return nil }
      return CGFloat(number)
    }

    private static func webView(in view: NSView) -> WKWebView? {
      if let web = view as? WKWebView { return web }
      for child in view.subviews {
        if let found = webView(in: child) { return found }
      }
      return nil
    }

    func route(_ event: NSEvent) -> NSEvent? {
      guard popover.isShown, let parent = window,
        parent.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
      let panel = popover.contentViewController?.view.window
      if event.type == .keyDown {
        if event.window === panel, event.keyCode == 53 {
          popover.performClose(nil)
          return nil
        }
      } else if event.window !== panel {
        // The anchor's own button toggles presentation after mouse-up.
        if event.window === parent, bounds.contains(convert(event.locationInWindow, from: nil)) {
          return event
        }
        popover.performClose(nil)
      }
      return event
    }

    func popoverDidClose(_ notification: Notification) {
      fitting?.cancel()
      fitting = nil
      dragOrigin = nil
      grip?.removeFromSuperview()
      grip = nil
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      popover.contentViewController = nil
      dismissed?()
    }

    func stop() {
      dismissed = nil
      fitting?.cancel()
      fitting = nil
      grip?.removeFromSuperview()
      grip = nil
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      popover.performClose(nil)
      workspace?.close()
      workspace = nil
    }
  }

  /// The panel's corner. Screen points, so the size tracks the cursor while
  /// the popover moves its top edge to stay on the status row.
  final class CornerGrip: NSView {
    /// How far the cursor has moved since the drag began, and whether it has ended.
    var onResize: ((_ delta: CGSize, _ ended: Bool) -> Void)?

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: NSCursor.frameResize(position: .topRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
      guard let window, let onResize else { return }
      let startMouse = NSEvent.mouseLocation
      while true {
        guard let tracked = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
        let now = NSEvent.mouseLocation
        let delta = CGSize(width: now.x - startMouse.x, height: now.y - startMouse.y)
        let ended = tracked.type == .leftMouseUp
        onResize(delta, ended)
        if ended { break }
      }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  }
}
#endif
