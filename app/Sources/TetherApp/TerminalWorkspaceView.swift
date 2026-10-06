#if os(macOS)
import AppKit
import SwiftUI

/// AppKit owns divider dragging and terminal view placement.
struct TerminalWorkspaceView: NSViewRepresentable {
  let workspace: TerminalWorkspace
  let tabs: TabSet
  let content: (SessionTab) -> AnyView

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.update(view, workspace: workspace, tabs: tabs, content: content)
  }

  @MainActor final class Coordinator: NSObject, NSSplitViewDelegate {
    var workspace: TerminalWorkspace?
    var tabs: TabSet?
    var hosts: [UUID: PaneHost] = [:]
    var splits: [ObjectIdentifier: [UUID]] = [:]
    var minimums: [ObjectIdentifier: (CGFloat, CGFloat)] = [:]
    var shape = ""
    var applying = false
    weak var container: NSView?

    func update(_ view: NSView, workspace: TerminalWorkspace, tabs: TabSet, content: (SessionTab) -> AnyView) {
      container = view
      self.workspace = workspace
      self.tabs = tabs
      let layout = workspace.maximized ? TerminalLayout.pane(workspace.focused) : workspace.layout
      let nextShape = signature(layout)
      applying = true
      defer { applying = false }
      for id in workspace.layout.leaves {
        guard let pane = tabs.tabs.first(where: { $0.id == id }) else { continue }
        if let host = hosts[id] { host.content.rootView = content(pane) }
        else {
          hosts[id] = PaneHost(content(pane)) { [weak tabs] in tabs?.focusPane(id) }
        }
      }
      for host in hosts.values { host.onGeometry = { [weak self] in self?.publishFrames() } }
      for id in hosts.keys.filter({ !workspace.layout.leaves.contains($0) }) { hosts.removeValue(forKey: id) }
      if nextShape != shape {
        shape = nextShape
        hosts.values.forEach { $0.removeFromSuperview() }
        view.subviews.forEach { $0.removeFromSuperview() }
        splits.removeAll()
        minimums.removeAll()
        let root = build(layout)
        root.frame = view.bounds
        root.autoresizingMask = [.width, .height]
        view.addSubview(root)
      }
      for (id, host) in hosts {
        host.layer?.borderColor = (workspace.focused == id ? NSColor.controlAccentColor : NSColor.clear).cgColor
        if workspace.focused == id && !host.wasFocused {
          DispatchQueue.main.async { [weak host] in if host?.wasFocused == true { host?.focusTerminal() } }
        }
        host.wasFocused = workspace.focused == id
      }
      let frames = hosts.compactMapValues { host -> CGRect? in
        guard host.window != nil, host.superview != nil else { return nil }
        return host.convert(host.bounds, to: view)
      }
      DispatchQueue.main.async { [weak workspace] in
        if workspace?.paneFrames != frames { workspace?.paneFrames = frames }
      }
    }

    func publishFrames() {
      DispatchQueue.main.async { [weak self] in
        guard let self, let workspace = self.workspace, let root = self.container else { return }
        let frames = self.hosts.compactMapValues { host -> CGRect? in
          guard host.window != nil, host.superview != nil else { return nil }
          return host.convert(host.bounds, to: root)
        }
        if workspace.paneFrames != frames { workspace.paneFrames = frames }
      }
    }
    func signature(_ node: TerminalLayout) -> String {
      switch node {
      case .pane(let id): return id.uuidString
      case .split(let vertical, _, let a, let b): return "\(vertical)(\(signature(a)),\(signature(b)))"
      }
    }
    func build(_ node: TerminalLayout) -> NSView {
      switch node {
      case .pane(let id): return hosts[id] ?? NSView()
      case .split(let vertical, let ratio, let a, let b):
        let split = ProportionalSplit()
        split.isVertical = !vertical
        split.dividerStyle = .thin
        split.initialRatio = min(0.9999, max(0.0001, ratio))
        split.addArrangedSubview(build(a))
        split.addArrangedSubview(build(b))
        split.delegate = self
        splits[ObjectIdentifier(split)] = node.leaves
        minimums[ObjectIdentifier(split)] = vertical ? (a.minimumSize.height, b.minimumSize.height) : (a.minimumSize.width, b.minimumSize.width)
        return split
      }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
      let extent = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
      let minimum = minimums[ObjectIdentifier(splitView)] ?? (160, 160)
      return extent >= minimum.0 + minimum.1 ? minimum.0 : max(0, extent / 2)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
      let extent = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
      let minimum = minimums[ObjectIdentifier(splitView)] ?? (160, 160)
      return extent >= minimum.0 + minimum.1 ? extent - minimum.1 : max(0, extent / 2)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
      guard !applying, let split = notification.object as? ProportionalSplit, !split.resizing,
        let ids = splits[ObjectIdentifier(split)], let workspace, !workspace.maximized,
        let first = split.arrangedSubviews.first else { return }
      let extent = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
      guard extent > 0 else { return }
      let ratio = (split.isVertical ? first.frame.width : first.frame.height) / extent
      split.initialRatio = ratio
      workspace.layout = workspace.layout.replacing(ids, ratio: ratio)
      tabs?.persistHistory()
      if let root = container {
        workspace.paneFrames = hosts.mapValues { $0.convert($0.bounds, to: root) }
      }
    }
  }

  @MainActor final class ProportionalSplit: NSSplitView {
    var initialRatio = 0.5
    var initialized = false
    var resizing = false
    override func resizeSubviews(withOldSize oldSize: NSSize) { applyRatio() }
    override func layout() {
      super.layout()
      if !initialized { applyRatio() }
    }
    private func applyRatio() {
      guard arrangedSubviews.count == 2 else { return }
      let extent = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
      guard extent > 0 else { return }
      resizing = true
      defer { resizing = false }
      initialized = true
      let first = extent * initialRatio
      if isVertical {
        arrangedSubviews[0].frame = CGRect(x: 0, y: 0, width: first, height: bounds.height)
        arrangedSubviews[1].frame = CGRect(x: first + dividerThickness, y: 0, width: extent - first, height: bounds.height)
      } else {
        arrangedSubviews[0].frame = CGRect(x: 0, y: 0, width: bounds.width, height: first)
        arrangedSubviews[1].frame = CGRect(x: 0, y: first + dividerThickness, width: bounds.width, height: extent - first)
      }
    }
  }

  @MainActor final class PaneHost: NSView {
    let content: NSHostingView<AnyView>
    let onFocus: () -> Void
    var monitor: Any?
    var wasFocused = false
    var onGeometry: (() -> Void)?
    init(_ view: AnyView, onFocus: @escaping () -> Void) {
      content = NSHostingView(rootView: view)
      self.onFocus = onFocus
      super.init(frame: .zero)
      wantsLayer = true
      layer?.borderWidth = 1
      addSubview(content)
    }
    required init?(coder: NSCoder) { return nil }
    override func layout() { super.layout(); content.frame = bounds.insetBy(dx: 1, dy: 1); onGeometry?() }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
        guard let self, event.window === self.window,
          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
        self.onFocus()
        return event
      }
    }
    func focusTerminal() {
      func responder(_ view: NSView) -> NSView? {
        for child in view.subviews { if let target = responder(child) { return target } }
        return view.acceptsFirstResponder ? view : nil
      }
      if let target = responder(content) { window?.makeFirstResponder(target) }
    }
  }
}
#endif
