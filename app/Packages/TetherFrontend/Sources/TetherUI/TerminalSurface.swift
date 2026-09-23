import SwiftUI
import Tether

#if os(macOS)
  import AppKit
#endif

/// The same terminal surface is used for a shell and every plugin-owned pane.
public struct TerminalSurface: View {
  let frame: ScreenFrame
  let active: Bool
  let inset: CGFloat
  let onInput: (TerminalInput) -> Void
  let onResize: (UInt16, UInt16) -> Void
  let onFocus: () -> Void
  let onScroll: (ScrollTo) -> Void
  let links: TerminalLinks
  /// The link under a ⌘-held pointer, underlined while it is.
  @State private var hovered: TerminalLink?
  /// Whether the hovered link is known to be there.
  @State private var confirmed = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("terminalFontSize") private var fontSize = 13.0
  @AppStorage("terminalAppearance") private var appearance = "system"

  public init(
    frame: ScreenFrame, active: Bool = true, inset: CGFloat = 8,
    onInput: @escaping (TerminalInput) -> Void,
    onResize: @escaping (UInt16, UInt16) -> Void = { _, _ in },
    onFocus: @escaping () -> Void = {},
    onScroll: @escaping (ScrollTo) -> Void = { _ in },
    links: TerminalLinks = .none
  ) {
    self.frame = frame
    self.active = active
    self.inset = inset
    self.onInput = onInput
    self.onResize = onResize
    self.onFocus = onFocus
    self.onScroll = onScroll
    self.links = links
  }
  public var body: some View {
    let metrics = FontMetrics(size: min(24, max(10, fontSize)))
    let palette = Palette.chosen(setting: appearance, scheme: scheme)
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        let cells = CellGeometry(
          cellWidth: metrics.cellWidth, lineHeight: metrics.lineHeight, inset: inset,
          columns: UInt16(frame.columns), rows: UInt16(frame.rows))
        TerminalView(frame: frame, metrics: metrics, palette: palette)
          .padding(inset)
        LinkUnderline(link: hovered, confirmed: confirmed, geometry: cells)
        KeyCapture(
          onInput: onInput, active: active, lineHeight: metrics.lineHeight,
          onFocus: onFocus, onScroll: { onScroll(.lines($0)) },
          links: links, geometry: cells, onHover: hover
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
            onScroll(.live)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .padding(10)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: frame.viewportOffset > 0)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(palette.background)
      .clipped()
      .onAppear { fit(geometry.size, metrics) }
      .onChange(of: geometry.size) { _, size in fit(size, metrics) }
      .onChange(of: fontSize) { _, _ in fit(geometry.size, metrics) }
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

  private func fit(_ size: CGSize, _ metrics: FontMetrics) {
    onResize(
      metrics.columns(fitting: size.width - inset * 2),
      metrics.rows(fitting: size.height - inset * 2))
  }
}
