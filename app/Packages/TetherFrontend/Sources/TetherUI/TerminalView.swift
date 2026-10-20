import SwiftUI
import Tether

/// Compatibility entry point. All terminal pixels are produced by tether-render.
public struct TerminalView: View {
  let frame: ScreenFrame
  let metrics: FontMetrics
  let palette: Palette

  public init(frame: ScreenFrame, metrics: FontMetrics, palette: Palette) {
    self.frame = frame
    self.metrics = metrics
    self.palette = palette
  }
  public var body: some View {
    WgpuTerminal(frame: frame, dirtyRows: nil, damageEpoch: 0, metrics: metrics, palette: palette, overlay: nil,
      onPresented: { _ in }, onScale: { _ in })
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}

/// Point-space geometry derived from the actual shared shaper. Native hosts
/// perform the scale conversion once; no platform font measurement is repeated.
public struct FontMetrics: Equatable, Sendable {
  let size: CGFloat
  let scale: CGFloat
  let primary: String
  let wide: String
  public let cellWidth: CGFloat
  public let lineHeight: CGFloat

  @MainActor
  public init(size: CGFloat, scale: CGFloat = 1, primary: String? = nil, wide: String? = nil) {
    let scale = max(scale, 1)
    let primary = TerminalFonts.resolvedPrimary(primary ?? TerminalFonts.primary)
    let wide = wide ?? TerminalFonts.wide
    let metrics = TerminalFonts.measure(size: size, scale: scale, primary: primary, wide: wide)
    self.size = size
    self.scale = scale
    self.primary = primary
    self.wide = wide
    cellWidth = CGFloat(metrics.cellWidth) / scale
    lineHeight = CGFloat(metrics.lineHeight) / scale
  }
  public func columns(fitting width: CGFloat) -> UInt16 {
    fitted(width, pitch: cellWidth, cap: 1000)
  }
  public func rows(fitting height: CGFloat) -> UInt16 {
    fitted(height, pitch: lineHeight, cap: 500)
  }

  /// Fit in integer device pixels. A point-space division at 125% lands one
  /// column short of the drawable the GPU was given.
  private func fitted(_ extent: CGFloat, pitch: CGFloat, cap: Int) -> UInt16 {
    let cell = pitch * scale
    guard cell > 0 else { return 1 }
    let pixels = (extent * scale).rounded()
    return UInt16(min(cap, max(1, Int((pixels / cell).rounded(.down)))))
  }
}
