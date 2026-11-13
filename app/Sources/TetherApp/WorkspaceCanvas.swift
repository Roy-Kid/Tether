import SwiftUI
import TetherPluginKit
#if os(macOS)
  import TetherUI

  /// The terminal canvas either host draws: the workspace's split of
  /// pages, or the one selected page. Both hosts render the same shared
  /// TabSet through the same interaction — the quick panel passively,
  /// the workspace window incrementally — and the canvas decides no
  /// business: links, drops and attachments run on the interaction.
  struct WorkspaceCanvas: View {
    @Bindable var tabs: TabSet
    let interaction: WorkspaceInteraction
    /// The interaction's gate: only the effective host takes typing.
    var inputAllowed: Bool
    /// The host the interaction names presents this tab's questions.
    var claimsDialogs: Bool
    /// True on the workspace window. A plugin's own views cannot live in
    /// two hosts, so where one stands in for a shell — or is the page —
    /// the quick panel draws the way to it instead of a second copy.
    var rendersPluginContent: Bool
    /// The quick panel draws whole frames and never acknowledges damage;
    /// the workspace window stays the one incremental consumer.
    var passive: Bool
    /// What fills the canvas when nothing is selected — each host's own
    /// welcome or offer.
    var placeholder: AnyView

    var body: some View {
      Group {
        if let layout = tabs.workspaceSplit, let workspace = tabs.currentWorkspace?.id {
          SplitCanvas(
            layout: layout, selected: tabs.selected, inputAllowed: inputAllowed,
            pane: { AnyView(page($0)) },
            onReplace: { tabs.replaceLayout(of: workspace, with: $0) },
            onCommit: { tabs.commitLayout() },
            onSelect: { tabs.select($0) },
            onPlace: { dragged, target, edge in _ = tabs.place(dragged, beside: target, edge: edge) })
        } else if let id = tabs.selected {
          page(id)
            .overlay { PaneDrop(target: id) { dragged, edge in _ = tabs.place(dragged, beside: id, edge: edge) } }
        } else {
          placeholder
        }
      }
      .terminalInputEnabled(inputAllowed)
    }

    @ViewBuilder
    private func page(_ id: UUID) -> some View {
      if let workspace = tabs.extensions.first(where: { $0.id == id })?.workspace {
        pluginPage(workspace.content().id(workspace.id))
      } else if let tab = tabs.tabs.first(where: { $0.id == id }) {
        Group {
          if let shown = tab.shown {
            pluginPage(shown.content().id(tab.id))
          } else {
            SessionView(
              tab: tab, links: interaction.links(for: tab), menuItems: tabs.terminalMenu(for: tab.id),
              active: tabs.selected == id, passive: passive, onFocus: { tabs.select(id) })
              .id(tab.id)
              .modifier(TerminalDrop(tab: tab) { interaction.drop($0, on: tab) })
          }
        }
        // The host the interaction names presents this tab's question:
        // one presenter, wherever the person is typing.
        .background(DialogAnchorReader(anchor: tab.dialogAnchor, claimsView: claimsDialogs))
      }
    }

    @ViewBuilder
    private func pluginPage<Content: View>(_ content: Content) -> some View {
      if rendersPluginContent {
        content.padding(Chrome.margin)
      } else {
        QuietMark("Shown in the Main Window", systemImage: "rectangle.on.rectangle")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  /// One split, sized from the fraction the page stored. A system split view
  /// keeps its own divider, and that divider is wrong after the panes leave
  /// the window and come back — and it draws through the tab strip.
  struct SplitCanvas: View {
    let layout: WorkspaceSplit
    let selected: UUID?
    let inputAllowed: Bool
    let pane: (UUID) -> AnyView
    let onReplace: (WorkspaceSplit) -> Void
    let onCommit: () -> Void
    let onSelect: (UUID) -> Void
    var onPlace: (UUID, UUID, SplitDirection) -> Void = { _, _, _ in }

    var body: some View {
      switch layout {
      case .tab(let id):
        pane(id)
          .terminalInputEnabled(inputAllowed && selected == id)
          .frame(minWidth: 120, maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
          .clipped()
          .contentShape(Rectangle())
          .simultaneousGesture(TapGesture().onEnded { onSelect(id) })
          .overlay { PaneDrop(target: id) { dragged, edge in onPlace(dragged, id, edge) } }
          .overlay(alignment: .top) {
            if selected == id {
              Rectangle().fill(Color.accentColor).frame(height: UIStyle.Mark.rule)
                .allowsHitTesting(false)
            }
          }
      case .split(let direction, let first, let second, let fraction):
        let vertical = direction == .up || direction == .down
        DividedPanes(axis: vertical ? .vertical : .horizontal, fraction: fraction, onFraction: { next in
          onReplace(.split(direction, first, second, next))
        }, onCommit: onCommit) {
          SplitCanvas(layout: first, selected: selected, inputAllowed: inputAllowed, pane: pane,
            onReplace: { onReplace(.split(direction, $0, second, fraction)) },
            onCommit: onCommit, onSelect: onSelect, onPlace: onPlace)
        } second: {
          SplitCanvas(layout: second, selected: selected, inputAllowed: inputAllowed, pane: pane,
            onReplace: { onReplace(.split(direction, first, $0, fraction)) },
            onCommit: onCommit, onSelect: onSelect, onPlace: onPlace)
        }
      }
    }
  }

  struct DividedPanes<First: View, Second: View>: View {
    var axis: Axis
    var fraction: Double
    var onFraction: (Double) -> Void
    var onCommit: () -> Void
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second
    @State private var dragStart: Double?

    var body: some View {
      GeometryReader { geometry in
        let horizontal = axis == .horizontal
        let length = horizontal ? geometry.size.width : geometry.size.height
        let minimum: CGFloat = horizontal ? 120 : 80
        let size = Self.length(fraction, usable: length, minimum: minimum)
        Group {
          if horizontal {
            HStack(spacing: 0) {
              first().frame(width: size).frame(maxHeight: .infinity)
              grip(horizontal: true, usable: length, minimum: minimum)
              second().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          } else {
            VStack(spacing: 0) {
              first().frame(height: size).frame(maxWidth: .infinity)
              grip(horizontal: false, usable: length, minimum: minimum)
              second().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
      }
    }

    /// The first pane's length. Below the minimum, both panes share what is left.
    private static func length(_ fraction: Double, usable: CGFloat, minimum: CGFloat) -> CGFloat {
      guard usable > 0 else { return 0 }
      let floor = min(minimum, usable / 2)
      let proposed = CGFloat(fraction.isFinite ? fraction : 0.5) * usable
      return min(max(proposed, floor), usable - floor)
    }

    private func grip(horizontal: Bool, usable: CGFloat, minimum: CGFloat) -> some View {
      Divider()
        .overlay {
          Color.clear
            .frame(width: horizontal ? Chrome.columnHandle : nil, height: horizontal ? nil : Chrome.columnHandle)
            .contentShape(Rectangle())
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            .gesture(
              DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                  guard usable > 0 else { return }
                  let origin = dragStart ?? fraction
                  dragStart = origin
                  let moved = horizontal ? value.translation.width : value.translation.height
                  let pixels = Self.length(origin, usable: usable, minimum: minimum) + moved
                  onFraction(Double(Self.length(pixels / usable, usable: usable, minimum: minimum) / usable))
                }
                .onEnded { _ in
                  dragStart = nil
                  onCommit()
                })
        }
        .accessibilityHidden(true)
    }
  }

  /// Drop a dragged tab on the side of a pane. The overlay stays out of the
  /// way until a drag is in progress, so typing and clicking still reach the shell.
  struct PaneDrop: NSViewRepresentable {
    var target: UUID
    var onPlace: (UUID, SplitDirection) -> Void

    func makeNSView(context: Context) -> Dropper {
      let view = Dropper()
      view.registerForDraggedTypes([TabDrag.type])
      return view
    }

    func updateNSView(_ view: Dropper, context: Context) {
      view.target = target
      view.onPlace = onPlace
    }

    final class Dropper: NSView {
      var target: UUID?
      var onPlace: ((UUID, SplitDirection) -> Void)?
      private let mark = CALayer()
      private var edge: SplitDirection?

      override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent, event.type == .leftMouseDragged else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
      }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = .clear
        mark.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        mark.isHidden = true
        if mark.superlayer == nil { layer?.addSublayer(mark) }
      }

      override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dragged = sender.draggingPasteboard.string(forType: TabDrag.type).flatMap(UUID.init),
          dragged != target else {
          hide()
          return []
        }
        let local = convert(sender.draggingLocation, from: nil)
        let point = bounds.contains(local) ? local : NSPoint(x: local.x, y: bounds.height - local.y)
        guard let side = SplitDirection.drop(
          x: point.x - bounds.minX, y: point.y - bounds.minY,
          width: bounds.width, height: bounds.height, band: 0.28)
        else {
          hide()
          return []
        }
        show(side)
        return .move
      }

      override func draggingExited(_ sender: NSDraggingInfo?) { hide() }

      override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hide() }
        guard let dragged = sender.draggingPasteboard.string(forType: TabDrag.type).flatMap(UUID.init),
          let target, let edge, dragged != target else { return false }
        onPlace?(dragged, edge)
        return true
      }

      private func show(_ side: SplitDirection) {
        edge = side
        let thickness = min(bounds.width, bounds.height) * 0.28
        let rect: CGRect
        switch side {
        case .left: rect = CGRect(x: 0, y: 0, width: thickness, height: bounds.height)
        case .right: rect = CGRect(x: bounds.width - thickness, y: 0, width: thickness, height: bounds.height)
        case .up: rect = CGRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness)
        case .down: rect = CGRect(x: 0, y: 0, width: bounds.width, height: thickness)
        }
        mark.isHidden = false
        mark.frame = rect
      }

      private func hide() {
        edge = nil
        mark.isHidden = true
      }
    }
  }

#endif

/// A path dragged from the files list is pasted as that absolute path.
/// Anything else that is a file is handed to `receiveFiles`. A Mac reads
/// the drop in AppKit (`TerminalDropContent`); a phone through SwiftUI.
struct TerminalDrop: ViewModifier {
  let tab: SessionTab
  let receiveFiles: ([URL]) -> Void

func body(content: Content) -> some View {
  #if os(macOS)
    content.terminalDrop(TerminalDropHandler(types: TerminalDropContent.types) { board in
      switch TerminalDropContent.read(board) {
      case .paste(let text):
        tab.send(.paste(text))
        return true
      case .files(let urls):
        receiveFiles(urls)
        return true
      case nil:
        return false
      }
    })
  #else
    phoneDrop(content)
  #endif
}

/// A phone's drag is SwiftUI's on both ends: one provider an item.
private func phoneDrop(_ content: Content) -> some View {
  content.onDrop(of: [DroppedPath.contentType, .fileURL], isTargeted: nil) { providers in
    let carried = providers.filter {
      $0.hasItemConformingToTypeIdentifier(DroppedPath.contentType.identifier)
    }
    if !carried.isEmpty {
      Task { @MainActor in
        var texts: [String] = []
        for provider in carried {
          if let item = await Self.load(DroppedPath.self, from: provider) {
            texts.append(item.text)
          }
        }
        let text = texts.joined(separator: "\n")
        guard !text.isEmpty else { return }
        tab.send(.paste(text))
      }
      return true
    }
    Task { @MainActor in
      var urls: [URL] = []
      for provider in providers {
        if let url = await Self.load(URL.self, from: provider), url.isFileURL {
          urls.append(url)
        }
      }
      receiveFiles(urls)
    }
    return !providers.isEmpty
  }
}

private static func load<T: Transferable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
  await withCheckedContinuation { continuation in
    _ = provider.loadTransferable(type: type) { result in
      continuation.resume(returning: try? result.get())
    }
  }
}
}
