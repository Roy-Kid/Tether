import SwiftUI
import Tether

/// Which path draws the grid. Settings store the raw value.
public enum TerminalDrawing: String {
  case canvas
  case metal

  /// Metal on both. The canvas stays as the fallback where there is no
  /// Metal device, and as a setting for comparing the two.
  public static var platformDefault: String { TerminalDrawing.metal.rawValue }
}

#if os(macOS)
  import AppKit
#endif

/// The same terminal surface is used for a shell and every plugin-owned pane.
public struct TerminalSurface: View {
  let frame: ScreenFrame
  /// `nil` redraws every row. An empty set redraws none of them.
  let dirtyRows: Set<Int>?
  let active: Bool
  let inset: CGFloat
  let onInput: (TerminalInput) -> Void
  let onResize: (UInt16, UInt16) -> Void
  let onFocus: () -> Void
  let onScroll: (ScrollTo) -> Void
  let links: TerminalLinks
  /// A measurement the caller already fitted to the space it has. Nil measures
  /// the setting's size. A second measurement at that size is larger than a
  /// fitted frame, and the last line is then clipped away.
  let metrics: FontMetrics?
  /// The link under a ⌘-held pointer, underlined while it is.
  @State private var hovered: TerminalLink?
  /// Cells a drag is covering. Nil is a click: nothing highlighted, and the
  /// clipboard left as it was.
  @State private var selection: GridSelection?
  /// Whether the hovered link is known to be there.
  @State private var confirmed = false
  /// The size last given to the session. A keyboard animation changes height
  /// on every frame; resizing on each of those is a SIGWINCH per frame.
  @State private var fittedWidth: CGFloat = 0
  @State private var pendingFit: Task<Void, Never>?
  /// Shared with the phone's key row, so a lit Ctrl is the chord that is sent.
  @State private var latch = Latch()
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("terminalFontSize") private var fontSize = 13.0
  @AppStorage("terminalAppearance") private var appearance = "system"
  @AppStorage("terminalDrawing") private var drawing = TerminalDrawing.platformDefault
  @State private var rowCache = RowPictureCache()

  public init(
    frame: ScreenFrame, dirtyRows: Set<Int>? = nil, active: Bool = true, inset: CGFloat = 8,
    onInput: @escaping (TerminalInput) -> Void,
    onResize: @escaping (UInt16, UInt16) -> Void = { _, _ in },
    onFocus: @escaping () -> Void = {},
    onScroll: @escaping (ScrollTo) -> Void = { _ in },
    links: TerminalLinks = .none,
    metrics: FontMetrics? = nil
  ) {
    self.frame = frame
    self.dirtyRows = dirtyRows
    self.active = active
    self.inset = inset
    self.onInput = onInput
    self.onResize = onResize
    self.onFocus = onFocus
    self.onScroll = onScroll
    self.links = links
    self.metrics = metrics
  }
  public var body: some View {
    let metrics = self.metrics ?? FontMetrics(size: min(24, max(10, fontSize)))
    let palette = Palette.chosen(setting: appearance, scheme: scheme)
    VStack(spacing: 0) {
      grid(metrics: metrics, palette: palette)
      #if os(iOS)
        TerminalKeyBar(latch: latch, onInput: onInput)
      #endif
    }
  }

  private func grid(metrics: FontMetrics, palette: Palette) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        let cells = CellGeometry(
          cellWidth: metrics.cellWidth, lineHeight: metrics.lineHeight, inset: inset,
          columns: UInt16(frame.columns), rows: UInt16(frame.rows))
        terminal(metrics: metrics, palette: palette)
          .padding(inset)
        SelectionHighlight(selection: selection, frame: frame, geometry: cells)
        LinkUnderline(link: hovered, confirmed: confirmed, geometry: cells)
        KeyCapture(
          onInput: { input in
            selection = nil
            onInput(input)
          }, active: active, lineHeight: metrics.lineHeight,
          onFocus: onFocus,
          onScroll: { lines in
            selection = nil
            onScroll(.lines(lines))
          },
          links: links, geometry: cells,
          cursorRect: CGRect(
            x: inset + CGFloat(frame.cursorColumn) * metrics.cellWidth,
            y: inset + CGFloat(frame.cursorRow) * metrics.lineHeight,
            width: metrics.cellWidth, height: metrics.lineHeight),
          onHover: hover, onSelection: applySelection, selection: selection, latch: latch
        )
        // Filled on purpose. A bare `NSView` has no intrinsic size, so
        // without this it lays out at zero — and a zero-sized view still
        // receives key events, because those follow the first responder,
        // while a wheel follows the pointer and finds nothing under it.
        // Measured: typing worked and scrolling did nothing at all.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Terminal")

        if frame.viewportOffset > 0 {
          // Reading history is a state someone can get stuck in — output
          // keeps arriving where they cannot see it. The way back is on
          // screen rather than a shortcut they have to know.
          Button("Jump to the present", systemImage: "arrow.down.to.line") {
            selection = nil
            onScroll(.live)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .padding(UIStyle.panelRadius)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: frame.viewportOffset > 0)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(palette.background)
      .clipped()
      .onAppear { applyFit(geometry.size, metrics) }
      .onChange(of: geometry.size) { _, size in noteSize(size, metrics) }
      .onChange(of: frame.columns) { _, _ in selection = nil }
      .onChange(of: frame.rows) { _, _ in selection = nil }
      .onChange(of: fontSize) { _, _ in
        rowCache.clear()
        applyFit(geometry.size, metrics)
      }
      .onChange(of: metrics.cellWidth) { _, _ in rowCache.clear() }
      .onChange(of: metrics.lineHeight) { _, _ in rowCache.clear() }
      .onChange(of: appearance) { _, _ in rowCache.clear() }
      .onChange(of: scheme) { _, _ in rowCache.clear() }
      .onDisappear { pendingFit?.cancel() }
    }
  }
  @ViewBuilder
  private func terminal(metrics: FontMetrics, palette: Palette) -> some View {
    let useMetal = drawing == TerminalDrawing.metal.rawValue && MetalTerminal.isAvailable
    if useMetal {
      MetalTerminal(frame: frame, dirtyRows: dirtyRows, metrics: metrics, palette: palette)
    } else {
      TerminalView(
        frame: frame, dirtyRows: dirtyRows, metrics: metrics, palette: palette, cache: rowCache)
    }
  }

  /// A drag highlights as it moves and copies when it ends. The text is taken
  /// from this frame, not from a selection stored a render ago: the last
  /// cell of a drag can arrive before SwiftUI has published the highlight.
  private func applySelection(_ update: SelectionUpdate) {
    switch update {
    case .highlight(let kind, let from, let to):
      selection = GridText.selection(kind, from: from, to: to, in: frame)
    case .copy(let kind, let from, let to):
      let resolved = GridText.selection(kind, from: from, to: to, in: frame)
      selection = resolved
      if let resolved { Clipboard.write(GridText.string(in: frame, selection: resolved)) }
    case .copyExisting(let existing):
      Clipboard.write(GridText.string(in: frame, selection: existing))
    case .clear:
      selection = nil
    }
  }

  /// Underlines a hovered link at once, dotted, and asks whether it is
  /// there: solid if it is, gone if it is not. Text that only looks like a
  /// path is not left promising a file.
  private func hover(_ link: TerminalLink?) {
    hovered = link
    confirmed = false
    guard let link else { return }
    let exists = links.exists
    Task { @MainActor in
      let there = await exists(link)
      guard hovered == link else { return }
      if there {
        confirmed = true
      } else {
        hovered = nil
        #if os(macOS)
          NSCursor.arrow.set()
        #endif
      }
    }
  }

  /// Width changes — rotation, a split — resize immediately, because the
  /// grid has to track the window. Height alone is what the software
  /// keyboard does while it animates, so that one waits until it settles
  /// and the session is told once.
  private func noteSize(_ size: CGSize, _ metrics: FontMetrics) {
    #if os(iOS)
      let widthChanged = abs(size.width - fittedWidth) > 0.5
      if widthChanged || fittedWidth == 0 {
        applyFit(size, metrics)
        return
      }
      pendingFit?.cancel()
      pendingFit = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        applyFit(size, metrics)
      }
    #else
      applyFit(size, metrics)
    #endif
  }

  private func applyFit(_ size: CGSize, _ metrics: FontMetrics) {
    pendingFit?.cancel()
    fittedWidth = size.width
    fit(size, metrics)
  }

  private func fit(_ size: CGSize, _ metrics: FontMetrics) {
    onResize(
      metrics.columns(fitting: size.width - inset * 2),
      metrics.rows(fitting: size.height - inset * 2))
  }
}
