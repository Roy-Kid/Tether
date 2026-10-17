import QuartzCore
import SwiftUI
import Tether

#if os(macOS)
  import AppKit
  typealias NativeTerminalView = NSView
#else
  import UIKit
  typealias NativeTerminalView = UIView
#endif

struct WgpuTerminal: View {
  let frame: ScreenFrame
  let dirtyRows: Set<Int>?
  let damageEpoch: Int
  let metrics: FontMetrics
  let palette: Palette
  let overlay: RenderOverlay?
  let onPresented: (Int) -> Void
  let onScale: (CGFloat) -> Void
  @State private var problem: Dialog?

  var body: some View {
    NativeTerminal(frame: frame, dirtyRows: dirtyRows, damageEpoch: damageEpoch, metrics: metrics,
      palette: palette, overlay: overlay, onPresented: onPresented, onScale: onScale) { error, retry, dismiss in
      problem = Dialog(title: "Terminal Rendering Failed", message: error.localizedDescription,
        actions: [.cancel("Close") { problem = nil; dismiss() }, .init("Retry") { _ in problem = nil; retry() }])
    }
    .dialog(for: problem?.id) { _ in problem! }
  }
}

private struct NativeTerminal {
  let frame: ScreenFrame
  let dirtyRows: Set<Int>?
  let damageEpoch: Int
  let metrics: FontMetrics
  let palette: Palette
  let overlay: RenderOverlay?
  let onPresented: (Int) -> Void
  let onScale: (CGFloat) -> Void
  let failure: (Error, @escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void

  @MainActor private func update(_ view: TerminalGPUView) {
    view.onFailure = failure
    view.onPresented = onPresented
    view.onScale = onScale
    view.update(frame: frame, dirtyRows: dirtyRows, damageEpoch: damageEpoch, metrics: metrics, palette: palette, overlay: overlay)
  }
}
#if os(macOS)
extension NativeTerminal: NSViewRepresentable {
  func makeNSView(context: Context) -> TerminalGPUView { let view = TerminalGPUView(); update(view); return view }
  func updateNSView(_ view: TerminalGPUView, context: Context) { update(view) }
  static func dismantleNSView(_ view: TerminalGPUView, coordinator: ()) { view.shutdown() }
}
#else
extension NativeTerminal: UIViewRepresentable {
  func makeUIView(context: Context) -> TerminalGPUView { let view = TerminalGPUView(); update(view); return view }
  func updateUIView(_ view: TerminalGPUView, context: Context) { update(view) }
  static func dismantleUIView(_ view: TerminalGPUView, coordinator: ()) { view.shutdown() }
}
#endif

/// Native presentation only. No glyphs, meshes, shaders or terminal layout.
@MainActor
final class TerminalGPUView: NativeTerminalView {
  private struct Pending {
    var frame: ScreenFrame
    var dirty: Set<Int>?
    var damageEpoch: Int
    var metrics: FontMetrics
    var palette: Palette
    var overlay: RenderOverlay?
  }
  private var pending: Pending?
  private var renderer: TerminalRenderer?
  private var initialization: Task<Void, Never>?
  private var draining: Task<Void, Never>?
  private var epoch = 0
  private var queued = false
  private var failed = false
  private var recovery = false
  /// Close dismissed the dialog. The refresh that clears it is not a new attempt.
  private var quietDismissal = false
  private var notedScale: CGFloat = 0
  private var pixelWidth: UInt32 = 0
  private var pixelHeight: UInt32 = 0
  private(set) var submittedFrames = 0
  var onFailure: ((Error, @escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?
  var onPresented: ((Int) -> Void)?
  var onScale: ((CGFloat) -> Void)?

  #if os(macOS)
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    init() {
      super.init(frame: .zero)
      wantsLayer = true
      for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification] {
        NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
      }
      NotificationCenter.default.addObserver(self, selector: #selector(resume), name: NSApplication.didUnhideNotification, object: nil)
    }
    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); noteScale(); window == nil ? shutdown() : schedule() }
    override func layout() { super.layout(); noteScale(); schedule() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); noteScale(); invalidate(); schedule() }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayScale: CGFloat { window?.backingScaleFactor ?? 1 }
    private var drawable: Bool {
      guard let window, !isHidden, window.isMiniaturized == false, !NSApplication.shared.isHidden else { return false }
      return window.occlusionState.contains(.visible)
    }
    @objc private func windowChanged(_ note: Notification) {
      guard let window, (note.object as? NSWindow) === window else { return }
      let visible = window.occlusionState.contains(.visible) || note.name == NSWindow.didDeminiaturizeNotification
      guard visible else { return }
      resume()
    }
  #else
    override class var layerClass: AnyClass { CAMetalLayer.self }
    init() {
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: UIScene.didActivateNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: UIScene.willDeactivateNotification, object: nil)
      registerForTraitChanges([UITraitDisplayScale.self]) { (view: TerminalGPUView, _: UITraitCollection) in
        view.noteScale()
        view.schedule()
      }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); noteScale(); window == nil ? shutdown() : schedule() }
    override func layoutSubviews() { super.layoutSubviews(); noteScale(); schedule() }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
    private var drawable: Bool {
      guard let window, !isHidden else { return false }
      return window.windowScene?.activationState == .foregroundActive
    }
    @objc private func sceneChanged(_ note: Notification) {
      guard let scene = note.object as? UIScene, scene === window?.windowScene else { return }
      guard scene.activationState == .foregroundActive else { return }
      invalidate()
      schedule()
    }
  #endif

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not from a nib") }

  func update(frame: ScreenFrame, dirtyRows: Set<Int>?, damageEpoch: Int, metrics: FontMetrics, palette: Palette, overlay: RenderOverlay?) {
    // Close holds until Retry. A newer frame must not clear that latch.
    if quietDismissal { return }
    let dirty: Set<Int>?
    if let pending {
      dirty = pending.dirty.flatMap { old in dirtyRows.map { old.union($0) } }
    } else { dirty = dirtyRows }
    pending = Pending(frame: frame, dirty: dirty, damageEpoch: damageEpoch, metrics: metrics, palette: palette, overlay: overlay)
    noteScale()
    schedule()
  }

  private func noteScale() {
    let scale = displayScale
    guard scale > 0, abs(scale - notedScale) > 0.01 else { return }
    let first = notedScale == 0
    notedScale = scale
    onScale?(scale)
    if !first { invalidate() }
  }

  private func invalidate() { pending?.dirty = nil; pixelWidth = 0; pixelHeight = 0 }
  @objc private func resume() { invalidate(); schedule() }

  private func schedule() {
    guard !queued, !failed, !quietDismissal else { return }
    queued = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.queued = false
      self.paint()
    }
  }

  private func paint() {
    guard !quietDismissal else { return }
    guard drawable, bounds.width > 0, bounds.height > 0, let pending else { return }
    if let error = TerminalFonts.failure { report(error); return }
    let scale = displayScale
    let width = UInt32(max(1, (bounds.width * scale).rounded()))
    let height = UInt32(max(1, (bounds.height * scale).rounded()))
    if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
    let drawableSize = CGSize(width: Int(width), height: Int(height))
    if metalLayer.drawableSize != drawableSize { metalLayer.drawableSize = drawableSize }
    guard let renderer else {
      guard initialization == nil, draining == nil else { return }
      do {
        let renderer = try TerminalRenderer(metalLayer: Unmanaged.passUnretained(metalLayer).toOpaque())
        self.renderer = renderer
        let capturedEpoch = epoch
        // Strong self and renderer keep the native target alive until even a
        // cancelled initialization has finished releasing its Rust surface.
        initialization = Task { @MainActor [self, renderer] in
          do {
            try await renderer.initialize(width: width, height: height)
            guard capturedEpoch == epoch, !Task.isCancelled else { renderer.close(); return }
            initialization = nil
            invalidate()
            schedule()
          } catch {
            renderer.close()
            guard capturedEpoch == epoch else { return }
            initialization = nil
            self.renderer = nil
            if !recovery { recovery = true; schedule() }
            else { report(error) }
          }
        }
      } catch {
        if !recovery { recovery = true; schedule() }
        else { report(error) }
      }
      return
    }
    guard initialization == nil else { return }
    do {
      if width != pixelWidth || height != pixelHeight {
        renderer.resize(width: width, height: height)
        pixelWidth = width
        pixelHeight = height
      }
      renderer.setFonts(primary: pending.metrics.primary, wide: pending.metrics.wide)
      let fontSize = Float(pending.metrics.size * scale)
      _ = try renderer.measure(size: fontSize)
      let epoch = pending.damageEpoch
      let presented = try renderer.draw(frame: pending.frame, palette: pending.palette.renderPalette, overlay: pending.overlay,
        fontSize: fontSize, dirtyRows: pending.dirty.map { $0.sorted().map(UInt32.init) })
      if !notePresent(presented, epoch: epoch) { schedule() }
    } catch {
      shutdown()
      if !recovery { recovery = true; schedule() }
      else { report(error) }
    }
  }

  /// A skipped acquire is not a presented frame. Damage stays where it is.
  @discardableResult
  func notePresent(_ presented: Bool, epoch: Int) -> Bool {
    guard presented else { return false }
    submittedFrames += 1
    pending?.dirty = []
    onPresented?(epoch)
    recovery = false
    return true
  }

  /// What Close on the rendering dialog does. Retry is the only way back.
  func dismissFromDialog() {
    quietDismissal = true
    failed = false
  }

  var holdsClosedDismissal: Bool { quietDismissal }

  private func report(_ error: Error) {
    failed = true
    onFailure?(error, { [weak self] in
      TerminalFonts.resetFailure()
      guard let self else { return }
      self.failed = false
      self.recovery = false
      self.quietDismissal = false
      self.invalidate()
      self.schedule()
    }, { [weak self] in
      self?.dismissFromDialog()
    })
  }

  func shutdown() {
    epoch += 1
    let inFlight = initialization
    inFlight?.cancel()
    initialization = nil
    renderer?.close()
    renderer = nil
    invalidate()
    if let inFlight {
      draining = Task { @MainActor [self, inFlight] in
        await inFlight.value
        draining = nil
        schedule()
      }
    }
  }
  deinit { NotificationCenter.default.removeObserver(self) }
}

extension Palette {
  var renderPalette: RenderPalette {
    RenderPalette(background: background.renderColor, foreground: foreground.renderColor,
      cursor: cursor.renderColor, ansi: (normal + bright).map(\.renderColor))
  }
}
extension Color {
  var renderColor: RenderColor {
    #if os(macOS)
      let native = NSColor(self).usingColorSpace(.sRGB) ?? .black
    #else
      let native = UIColor(self)
    #endif
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    native.getRed(&r, green: &g, blue: &b, alpha: &a)
    return RenderColor(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a))
  }
}
