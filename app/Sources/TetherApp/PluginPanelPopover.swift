#if os(macOS)
import AppKit
import SwiftUI
import TetherPluginKit

/// A plugin panel stays alive while its permission sheet owns the keyboard.
/// A transient system popover would close and cancel that same request.
struct PluginPanelPopover: NSViewRepresentable {
  @Binding var isPresented: Bool
  let workspace: (any PluginWorkspace)?

  func makeNSView(context: Context) -> Anchor { Anchor() }
  func updateNSView(_ view: Anchor, context: Context) {
    view.dismissed = { isPresented = false }
    view.presented = isPresented
    view.workspace = workspace
    view.updatePresentation()
  }
  static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }

  final class Anchor: NSView, NSPopoverDelegate {
    let popover = NSPopover()
    var presented = false
    var workspace: (any PluginWorkspace)?
    var dismissed: (() -> Void)?
    private var monitor: Any?

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
      popover.contentViewController = NSHostingController(rootView: workspace.content())
      popover.contentSize = NSSize(width: 400, height: 450)
      popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
        [weak self] event in
        guard let self else { return event }
        return self.route(event)
      }
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
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      popover.contentViewController = nil
      dismissed?()
    }

    func stop() {
      dismissed = nil
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      popover.performClose(nil)
      workspace?.close()
      workspace = nil
    }
  }
}
#endif
