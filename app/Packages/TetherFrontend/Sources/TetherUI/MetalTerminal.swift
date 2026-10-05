import CoreText
import Metal
import MetalKit
import SwiftUI
import Tether

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Columns a row's runs occupy, never past the screen.
enum MetalMesh {
  static func coveredColumns(_ line: ScreenRow, limit: Int) -> Int {
    let covered = line.runs.reduce(0) { $0 + Int($1.columns) }
    return min(max(limit, 0), max(covered, 0))
  }

  /// The rows a view has to build: every one it was told changed, and every
  /// one it has never built. `dirty` describes the frame before this one,
  /// not what this view holds — a view made for a frame already on screen,
  /// as going back to a tab makes, holds nothing, whatever changed last.
  static func rowsToBuild(dirty: Set<Int>?, lines: Int, built: Set<Int>) -> [Int] {
    let rows = 0..<max(lines, 0)
    guard let dirty else { return Array(rows) }
    return rows.filter { dirty.contains($0) || !built.contains($0) }
  }
}

struct MetalTerminal: View {
  static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

  let frame: ScreenFrame
  let dirtyRows: Set<Int>?
  let metrics: FontMetrics
  let palette: Palette

  var body: some View {
    MetalTerminalRepresentable(
      frame: frame, dirtyRows: dirtyRows, metrics: metrics, palette: palette)
  }
}

#if os(macOS)
  private struct MetalTerminalRepresentable: NSViewRepresentable {
    let frame: ScreenFrame
    let dirtyRows: Set<Int>?
    let metrics: FontMetrics
    let palette: Palette

    func makeNSView(context: Context) -> TerminalMetalView {
      let view = TerminalMetalView(device: MTLCreateSystemDefaultDevice()!)
      sync(view)
      return view
    }

    func updateNSView(_ view: TerminalMetalView, context: Context) {
      sync(view)
    }

    private func sync(_ view: TerminalMetalView) {
      view.present(frame: frame, dirtyRows: dirtyRows, metrics: metrics, palette: palette)
    }
  }
#else
  private struct MetalTerminalRepresentable: UIViewRepresentable {
    let frame: ScreenFrame
    let dirtyRows: Set<Int>?
    let metrics: FontMetrics
    let palette: Palette

    func makeUIView(context: Context) -> TerminalMetalView {
      let view = TerminalMetalView(device: MTLCreateSystemDefaultDevice()!)
      sync(view)
      return view
    }

    func updateUIView(_ view: TerminalMetalView, context: Context) {
      sync(view)
    }

    private func sync(_ view: TerminalMetalView) {
      view.present(frame: frame, dirtyRows: dirtyRows, metrics: metrics, palette: palette)
    }
  }
#endif

private struct Vertex {
  var x, y, u, v: Float
  var r, g, b, a: Float
}

/// What a Metal view drew, read back. For tests: nothing else looks at it.
struct MetalSnapshot {
  let width: Int
  let height: Int
  let bytes: [UInt8]

  /// Blue, green and red, packed; alpha apart.
  func rgb(x: Int, y: Int) -> UInt32 {
    let index = (y * width + x) * 4
    return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
  }

  func alpha(x: Int, y: Int) -> UInt8 {
    bytes[(y * width + x) * 4 + 3]
  }
}

final class TerminalMetalView: MTKView, MTKViewDelegate {
  private var screen: ScreenFrame?
  private var metrics = FontMetrics(size: 13)
  private var palette = Palette.dark
  private var pipeline: MTLRenderPipelineState?
  private var queue: MTLCommandQueue?
  private var atlas: GlyphAtlas?
  private var rowVertices: [Int: [Vertex]] = [:]
  // Immutable while commands are in flight. Cursor-only updates reuse it.
  private var screenBuffer: MTLBuffer?
  private var screenVertexCount = 0
  private var screenBufferDirty = true
  /// The scale the built rows' glyphs were rasterized at.
  private var builtScale: CGFloat = 0
  private let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float2 p; float2 uv; float4 c; };
    struct O { float4 p [[position]]; float2 uv; float4 c; };
    vertex O vs(uint id [[vertex_id]], const device V *v [[buffer(0)]], constant float2 &view [[buffer(1)]]) {
      V in = v[id];
      O o;
      o.p = float4(in.p.x / view.x * 2.0 - 1.0, 1.0 - in.p.y / view.y * 2.0, 0, 1);
      o.uv = in.uv;
      o.c = in.c;
      return o;
    }
    fragment float4 fs(O in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
      constexpr sampler s(filter::linear);
      return float4(in.c.rgb, in.c.a * atlas.sample(s, in.uv).r);
    }
    """

  init(device: MTLDevice) {
    super.init(frame: .zero, device: device)
    framebufferOnly = false
    isPaused = true
    enableSetNeedsDisplay = true
    delegate = self
    colorPixelFormat = .bgra8Unorm
    queue = device.makeCommandQueue()
    atlas = GlyphAtlas(device: device)
    if let library = try? device.makeLibrary(source: source, options: nil),
      let vertex = library.makeFunction(name: "vs"),
      let fragment = library.makeFunction(name: "fs")
    {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = vertex
      descriptor.fragmentFunction = fragment
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      descriptor.colorAttachments[0].isBlendingEnabled = true
      descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
      descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
      // Alpha blends too. Left at its default a glyph's transparent texels
      // wrote alpha 0 over the opaque background, and every drawn cell was
      // a hole wherever the layer is composited.
      descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
      descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
      pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("not from a nib") }

  /// Drawing only. A wheel and a drag follow the view under the pointer; if
  /// this one is in front it swallows both, and typing still works because
  /// keys follow the first responder rather than the pointer.
  #if os(macOS)
    override func hitTest(_: NSPoint) -> NSView? { nil }
  #else
    override func point(inside _: CGPoint, with _: UIEvent?) -> Bool { false }
  #endif

  func present(frame: ScreenFrame, dirtyRows: Set<Int>?, metrics: FontMetrics, palette: Palette) {
    // Positions, colours and glyph resolution are baked into a row's
    // vertices: a new cell size, palette or display scale makes every row
    // stale, not only the changed ones.
    let restyled = metrics.cellWidth != self.metrics.cellWidth || metrics.lineHeight != self.metrics.lineHeight
      || palette != self.palette || contentScale != builtScale
      || screen?.columns != frame.columns || screen?.rows != frame.rows
    if restyled {
      rowVertices.removeAll()
      screenBufferDirty = true
    }
    screen = frame
    self.metrics = metrics
    self.palette = palette
    build(MetalMesh.rowsToBuild(dirty: dirtyRows, lines: frame.lines.count, built: Set(rowVertices.keys)))
    if rowVertices.keys.contains(where: { !frame.lines.indices.contains($0) }) {
      rowVertices = rowVertices.filter { frame.lines.indices.contains($0.key) }
      screenBufferDirty = true
    }
    requestDraw()
  }

  /// Builds `rows`. A glyph atlas that had to start again invalidates every
  /// row built before it did, so then the whole screen is built once more.
  private func build(_ rows: [Int]) {
    guard let atlas, let screen else { return }
    if !rows.isEmpty { screenBufferDirty = true }
    builtScale = contentScale
    atlas.allowsReset = true
    let generation = atlas.generation
    for row in rows { rowVertices[row] = vertices(for: row) }
    guard atlas.generation != generation else { return }
    // Once per build: a single screen that needs more than the atlas holds
    // draws what fits rather than starting over for ever.
    atlas.allowsReset = false
    rowVertices.removeAll()
    for row in screen.lines.indices { rowVertices[row] = vertices(for: row) }
  }

  private func rebuildAll() {
    guard let screen else { return }
    rowVertices.removeAll()
    screenBufferDirty = true
    build(Array(screen.lines.indices))
    requestDraw()
  }

  private func requestDraw() {
    #if os(macOS)
      setNeedsDisplay(bounds)
    #else
      setNeedsDisplay()
    #endif
  }

  // A view is made before it has a window, and a window can move to a
  // display of another scale. Glyphs rasterized for the wrong one are soft.
  #if os(macOS)
    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      if contentScale != builtScale { rebuildAll() }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil, contentScale != builtScale { rebuildAll() }
    }
  #else
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil, contentScale != builtScale { rebuildAll() }
    }
  #endif

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    // The drawable is new. Drawing into it is what fills the area the
    // window just gained; leaving the callback empty kept the previous
    // texture scaled over the new size until the next keystroke.
    requestDraw()
  }

  func draw(in view: MTKView) {
    guard let drawable = currentDrawable, let descriptor = currentRenderPassDescriptor else { return }
    let points = SIMD2<Float>(
      Float(drawableSize.width / contentScale), Float(drawableSize.height / contentScale))
    guard let command = encode(into: descriptor, points: points) else { return }
    command.present(drawable)
    command.commit()
  }

  /// Draws the screen into a texture of `width` × `height` points and reads
  /// it back — the same encoding the window gets.
  func snapshot(width: Int, height: Int, scale: Int) -> MetalSnapshot? {
    guard let device, width > 0, height > 0 else { return nil }
    let pixelsWide = width * scale
    let pixelsHigh = height * scale
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: pixelsWide, height: pixelsHigh, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].storeAction = .store
    guard let command = encode(into: pass, points: SIMD2(Float(width), Float(height))) else { return nil }
    command.commit()
    command.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh * 4)
    target.getBytes(
      &bytes, bytesPerRow: pixelsWide * 4, from: MTLRegionMake2D(0, 0, pixelsWide, pixelsHigh), mipmapLevel: 0)
    return MetalSnapshot(width: pixelsWide, height: pixelsHigh, bytes: bytes)
  }

  /// One pass: the background, every row's quads, and the cursor.
  private func encode(into descriptor: MTLRenderPassDescriptor, points: SIMD2<Float>) -> MTLCommandBuffer? {
    guard let pipeline, let queue, let atlas else { return nil }
    let background = rgba(palette.background)
    descriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: Double(background.0), green: Double(background.1), blue: Double(background.2), alpha: 1)
    descriptor.colorAttachments[0].loadAction = .clear
    guard let command = queue.makeCommandBuffer(),
      let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
    else { return nil }
    if screenBufferDirty {
      var vertices: [Vertex] = []
      vertices.reserveCapacity(rowVertices.values.reduce(0) { $0 + $1.count })
      if let screen {
        for index in screen.lines.indices {
          vertices.append(contentsOf: rowVertices[index] ?? [])
        }
      }
      screenVertexCount = vertices.count
      screenBuffer = vertices.isEmpty ? nil : device?.makeBuffer(
        bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count)
      screenBufferDirty = !vertices.isEmpty && screenBuffer == nil
    }
    var viewSize = SIMD2<Float>(max(points.x, 1), max(points.y, 1))
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.setFragmentTexture(atlas.texture, index: 0)
    if let screenBuffer, screenVertexCount > 0 {
      encoder.setVertexBuffer(screenBuffer, offset: 0, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: screenVertexCount)
    }
    if let screen {
      let cursor = cursorVertices(screen)
      if !cursor.isEmpty {
        // A cursor is six vertices, small enough for Metal's inline storage.
        encoder.setVertexBytes(cursor, length: MemoryLayout<Vertex>.stride * cursor.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cursor.count)
      }
    }
    encoder.endEncoding()
    return command
  }

  private var contentScale: CGFloat {
    #if os(macOS)
      window?.backingScaleFactor ?? 2
    #else
      window?.screen.scale ?? traitCollection.displayScale
    #endif
  }

  private func vertices(for row: Int) -> [Vertex] {
    guard let screen, let atlas, screen.lines.indices.contains(row) else { return [] }
    let line = screen.lines[row]
    var column = 0
    var vertices: [Vertex] = []
    let limit = MetalMesh.coveredColumns(line, limit: Int(screen.columns))
    for run in line.runs {
      if column >= limit { break }
      let width = min(Int(run.columns), limit - column)
      guard width > 0 else { break }
      let foreground = rgba(palette.color(run.style.inverse ? run.style.background : run.style.foreground))
      let background = rgba(palette.color(run.style.inverse ? run.style.foreground : run.style.background))
      let origin = CGPoint(x: metrics.cellWidth * CGFloat(column), y: metrics.lineHeight * CGFloat(row))
      let size = CGSize(width: metrics.cellWidth * CGFloat(width), height: metrics.lineHeight)
      if background != rgba(palette.background) {
        vertices.append(contentsOf: quad(origin, size, uv: atlas.solid, color: background))
      }
      if !run.style.hidden, !run.text.allSatisfy(\.isWhitespace) {
        let color = run.style.dim ? (foreground.0, foreground.1, foreground.2, foreground.3 * 0.6) : foreground
        vertices.append(contentsOf: glyphs(run, at: origin, column: column, limit: limit, width: width, color: color))
        for line in MetalMesh.decorations(run.style, origin: origin, size: size) {
          vertices.append(contentsOf: quad(line.origin, line.size, uv: atlas.solid, color: color))
        }
      }
      column += width
    }
    return vertices
  }

  /// One cluster per cell span, each placed on its own cells rather than
  /// advanced by the font — the grid, not the face, decides where it goes.
  private func glyphs(
    _ run: StyledRun, at origin: CGPoint, column: Int, limit: Int, width: Int,
    color: (Float, Float, Float, Float)
  ) -> [Vertex] {
    guard let atlas else { return [] }
    var clusters: [String] = []
    run.text.enumerateSubstrings(
      in: run.text.startIndex..<run.text.endIndex, options: .byComposedCharacterSequences
    ) { cluster, _, _, _ in
      if let cluster { clusters.append(cluster) }
    }
    let each = max(1, width / max(clusters.count, 1))
    var vertices: [Vertex] = []
    var placed = 0
    for cluster in clusters {
      if column + placed >= limit { break }
      let span = min(each, limit - (column + placed))
      let glyphOrigin = CGPoint(x: metrics.cellWidth * CGFloat(column + placed), y: origin.y)
      let glyphSize = CGSize(width: metrics.cellWidth * CGFloat(span), height: metrics.lineHeight)
      if let uv = atlas.glyph(
        cluster, bold: run.style.bold, italic: run.style.italic, points: glyphSize, fontSize: metrics.size,
        scale: contentScale)
      {
        vertices.append(contentsOf: quad(glyphOrigin, glyphSize, uv: uv, color: color))
      }
      placed += span
    }
    return vertices
  }

  private func cursorVertices(_ screen: ScreenFrame) -> [Vertex] {
    guard screen.cursorVisible, screen.cursorShape != .hidden else { return [] }
    let x = metrics.cellWidth * CGFloat(screen.cursorColumn)
    let y = metrics.lineHeight * CGFloat(screen.cursorRow)
    let rect: CGRect =
      switch screen.cursorShape {
      case .block:
        CGRect(x: x, y: y, width: metrics.cellWidth, height: metrics.lineHeight)
      case .underline:
        CGRect(x: x, y: y + metrics.lineHeight - 2, width: metrics.cellWidth, height: 2)
      case .beam:
        CGRect(x: x, y: y, width: 2, height: metrics.lineHeight)
      case .hidden:
        .null
      }
    guard !rect.isNull, let atlas else { return [] }
    var color = rgba(palette.cursor)
    color.3 = 0.75
    return quad(rect.origin, rect.size, uv: atlas.solid, color: color)
  }

  private func quad(
    _ origin: CGPoint, _ size: CGSize, uv: SIMD4<Float>, color: (Float, Float, Float, Float)
  ) -> [Vertex] {
    let x0 = Float(origin.x), y0 = Float(origin.y)
    let x1 = Float(origin.x + size.width), y1 = Float(origin.y + size.height)
    let vertex = { (x: Float, y: Float, u: Float, v: Float) in
      Vertex(x: x, y: y, u: u, v: v, r: color.0, g: color.1, b: color.2, a: color.3)
    }
    return [
      vertex(x0, y0, uv.x, uv.y), vertex(x1, y0, uv.z, uv.y), vertex(x0, y1, uv.x, uv.w),
      vertex(x0, y1, uv.x, uv.w), vertex(x1, y0, uv.z, uv.y), vertex(x1, y1, uv.z, uv.w),
    ]
  }

  private func rgba(_ color: Color) -> (Float, Float, Float, Float) {
    #if os(macOS)
      let native = NSColor(color).usingColorSpace(.sRGB) ?? .black
    #else
      let native = UIColor(color)
    #endif
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    native.getRed(&r, green: &g, blue: &b, alpha: &a)
    return (Float(r), Float(g), Float(b), Float(a))
  }
}

extension MetalMesh {
  /// Where a run's underline and strike-through go, in the cell box the
  /// glyphs were rasterized into — their baseline is 15% up from the bottom.
  /// Every underline style is drawn as one line, as the canvas draws it.
  static func decorations(_ style: CellStyle, origin: CGPoint, size: CGSize) -> [CGRect] {
    let thickness: CGFloat = 1
    var lines: [CGRect] = []
    if style.underline != .none {
      let baseline = origin.y + size.height * 0.85
      lines.append(CGRect(x: origin.x, y: min(baseline + 1, origin.y + size.height - thickness), width: size.width, height: thickness))
    }
    if style.strikethrough {
      lines.append(CGRect(x: origin.x, y: origin.y + size.height * 0.55, width: size.width, height: thickness))
    }
    return lines
  }
}

/// Every glyph drawn, rasterized once into one texture.
final class GlyphAtlas {
  let texture: MTLTexture
  /// UV of the opaque block's centre, x0 y0 x1 y1 — one point, so every
  /// sample of it is fully opaque.
  let solid: SIMD4<Float>
  /// Changes when the atlas starts again. Every UV handed out before is gone.
  private(set) var generation = 0
  /// Whether a full atlas may start again. A caller rebuilding the screen
  /// after one restart turns this off, so one screen cannot loop.
  var allowsReset = true
  private var slots: [Key: SIMD4<Float>] = [:]
  private var penX = GlyphAtlas.firstSlot
  private var penY = GlyphAtlas.firstSlot
  private var rowHeight = 0
  private let side: Int
  /// Glyphs start past the opaque block in the corner.
  private static let firstSlot = 4

  private struct Key: Hashable {
    var text: String
    var bold: Bool
    var italic: Bool
    var width: Int
    var height: Int
  }

  init(device: MTLDevice, side: Int = 2048) {
    self.side = side
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
    descriptor.usage = [.shaderRead]
    texture = device.makeTexture(descriptor: descriptor) ?? device.makeTexture(
      descriptor: MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false))!
    // A 3×3 opaque block, sampled only at its centre. One opaque texel
    // sampled across its width blended into its empty neighbour under
    // linear filtering, and every solid quad — cursor, background, line —
    // faded from one corner to the other.
    var white = [UInt8](repeating: 255, count: 9)
    texture.replace(region: MTLRegionMake2D(0, 0, 3, 3), mipmapLevel: 0, withBytes: &white, bytesPerRow: 3)
    let centre = 1.5 / Float(side)
    solid = SIMD4(centre, centre, centre, centre)
  }

  /// Rasterized at the display's own scale: at 2× on a 3× phone every
  /// character is soft, and at 2× on a 1× display it is twice the work.
  func glyph(
    _ text: String, bold: Bool, italic: Bool, points: CGSize, fontSize: CGFloat, scale: CGFloat
  ) -> SIMD4<Float>? {
    let width = max(1, Int((points.width * scale).rounded()))
    let height = max(1, Int((points.height * scale).rounded()))
    let key = Key(text: text, bold: bold, italic: italic, width: width, height: height)
    if let cached = slots[key] { return cached }
    guard width + 3 < side, height + 3 < side,
      let bytes = raster(text, bold: bold, italic: italic, width: width, height: height, fontSize: fontSize * scale)
    else { return nil }
    if penX + width + 1 >= side {
      penX = GlyphAtlas.firstSlot
      penY += rowHeight + 1
      rowHeight = 0
    }
    if penY + height >= side {
      guard allowsReset else { return nil }
      startAgain()
    }
    bytes.withUnsafeBytes { raw in
      texture.replace(
        region: MTLRegionMake2D(penX, penY, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!,
        bytesPerRow: width)
    }
    let s = Float(side)
    let uv = SIMD4(Float(penX) / s, Float(penY) / s, Float(penX + width) / s, Float(penY + height) / s)
    slots[key] = uv
    penX += width + 1
    rowHeight = max(rowHeight, height)
    return uv
  }

  /// Forgets every glyph. The opaque block in the corner stays.
  private func startAgain() {
    slots.removeAll()
    penX = GlyphAtlas.firstSlot
    penY = GlyphAtlas.firstSlot
    rowHeight = 0
    generation += 1
  }

  private func raster(
    _ text: String, bold: Bool, italic: Bool, width: Int, height: Int, fontSize: CGFloat
  ) -> [UInt8]? {
    #if os(macOS)
      let base = NSFont.monospacedSystemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
    #else
      let base = UIFont.monospacedSystemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
    #endif
    var font = base as CTFont
    if italic, let styled = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) {
      font = styled
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: platformWhite()]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: 0, y: CGFloat(height) * 0.15)
    CTLineDraw(line, context)
    var alpha = [UInt8](repeating: 0, count: width * height)
    for index in 0..<width * height {
      alpha[index] = pixels[index * 4 + 3]
    }
    return alpha
  }

  private func platformWhite() -> Any {
    #if os(macOS)
      NSColor.white
    #else
      UIColor.white
    #endif
  }
}
