import SwiftUI
import Tether

/// The same terminal surface is used for a shell and every plugin-owned pane.
public struct TerminalSurface: View {
  let frame: ScreenFrame
  let active: Bool
  let inset: CGFloat
  let onInput: (TerminalInput) -> Void
  let onResize: (UInt16, UInt16) -> Void
  let onFocus: () -> Void
  let onScroll: (ScrollTo) -> Void
  @Environment(\.colorScheme) private var scheme
  @AppStorage("terminalFontSize") private var fontSize = 13.0
  @AppStorage("terminalAppearance") private var appearance = "system"
  /// Lines already sent for the drag in progress, so each `onChanged` asks
  /// for the difference rather than the total.
  @State private var carried: Int32 = 0

  public init(
    frame: ScreenFrame, active: Bool = true, inset: CGFloat = 8,
    onInput: @escaping (TerminalInput) -> Void,
    onResize: @escaping (UInt16, UInt16) -> Void = { _, _ in },
    onFocus: @escaping () -> Void = {},
    onScroll: @escaping (ScrollTo) -> Void = { _ in }
  ) {
    self.frame = frame
    self.active = active
    self.inset = inset
    self.onInput = onInput
    self.onResize = onResize
    self.onFocus = onFocus
    self.onScroll = onScroll
  }
  public var body: some View {
    let metrics = FontMetrics(size: min(24, max(10, fontSize)))
    let dark = appearance == "dark" || (appearance == "system" && scheme == .dark)
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        TerminalView(frame: frame, metrics: metrics, palette: dark ? .dark : .light)
          .padding(inset)
        KeyCapture(
          onInput: onInput, active: active, lineHeight: metrics.lineHeight,
          onFocus: onFocus, onScroll: { onScroll(.lines($0)) }
        )
        // Filled on purpose. A bare `NSView` has no intrinsic size, so
        // without this it lays out at zero — and a zero-sized view still
        // receives key events, because those follow the first responder,
        // while a wheel follows the pointer and finds nothing under it.
        // Measured: typing worked and scrolling did nothing at all.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Terminal")

        // Touch reads the history by dragging the screen. A Mac has a wheel
        // for this and would rather keep the drag for selecting text.
        #if !os(macOS)
          dragToScroll(metrics)
        #endif

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
      .animation(.easeOut(duration: 0.12), value: frame.viewportOffset > 0)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(dark ? Palette.dark.background : Palette.light.background)
      .clipped()
      .onAppear { fit(geometry.size, metrics) }
      .onChange(of: geometry.size) { _, size in fit(size, metrics) }
      .onChange(of: fontSize) { _, _ in fit(geometry.size, metrics) }
    }
  }
  /// Dragging the screen moves the viewport, a line at a time.
  private func dragToScroll(_ metrics: FontMetrics) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 6)
          .onChanged { value in
            // Whole lines only: a terminal's history has no half-rows to stop
            // between, and each change asks for the difference rather than
            // the total so the two do not compound.
            let lines = Int32((value.translation.height / metrics.lineHeight).rounded())
            guard lines != carried else { return }
            onScroll(.lines(lines - carried))
            carried = lines
          }
          .onEnded { _ in carried = 0 })
      .allowsHitTesting(frame.historyLines > 0)
  }

  private func fit(_ size: CGSize, _ metrics: FontMetrics) {
    onResize(
      UInt16(min(1000, max(1, (size.width - inset * 2) / metrics.cellWidth))),
      UInt16(min(500, max(1, (size.height - inset * 2) / metrics.lineHeight))))
  }
}
