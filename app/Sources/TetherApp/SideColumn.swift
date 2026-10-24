#if os(macOS)
  import SwiftUI

  /// A column beside the canvas that keeps the width it was given.
  ///
  /// `HSplitView` is an `NSSplitView`, which shares every change of window
  /// width among its panes — and a move to another display is one, because
  /// the window lays out again there. A side panel then grew and shrank with
  /// the window. Here only the canvas takes up the difference; the column
  /// changes when its edge is dragged, and the width it is left at is kept.
  struct SideColumn<Content: View>: View {
    enum Side { case leading, trailing }

    let side: Side
    @Binding var width: Double
    let range: ClosedRange<CGFloat>
    @ViewBuilder var content: Content
    /// The width when a drag began: the drag adds to that, not to every step.
    @State private var dragStart: CGFloat?

    static func clamped(_ width: Double, to range: ClosedRange<CGFloat>) -> CGFloat {
      guard width.isFinite else { return range.lowerBound }
      return min(max(CGFloat(width), range.lowerBound), range.upperBound)
    }

    var body: some View {
      let current = Self.clamped(width, to: range)
      HStack(spacing: 0) {
        if side == .trailing { edge(current) }
        content.frame(width: current)
        if side == .leading { edge(current) }
      }
    }

    /// The hairline between column and canvas, with a few points either side
    /// to take the drag.
    private func edge(_ current: CGFloat) -> some View {
      Divider()
        .overlay {
          Color.clear
            .frame(width: Chrome.columnHandle)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
              DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                  let start = dragStart ?? current
                  dragStart = start
                  let moved = side == .trailing ? -value.translation.width : value.translation.width
                  width = Double(Self.clamped(Double(start + moved), to: range))
                }
                .onEnded { _ in dragStart = nil })
        }
        .accessibilityHidden(true)
    }
  }
#endif
