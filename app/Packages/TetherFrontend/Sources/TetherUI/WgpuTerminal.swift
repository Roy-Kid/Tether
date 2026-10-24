import QuartzCore
import SwiftUI
import Tether

#if os(macOS)
  import AppKit
  typealias NativeTerminalView = NSView

  /// `configure` disables this, and `nextDrawable` then waits on the calling
  /// thread until a drawable exists. That wait never ends while the same
  /// thread still owes Core Animation the commit that would create one.
  private final class TimeoutMetalLayer: CAMetalLayer {
    override var allowsNextDrawableTimeout: Bool {
      get { super.allowsNextDrawableTimeout }
      set { super.allowsNextDrawableTimeout = true }
    }
  }
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
  /// The margin round the grid, in device pixels; the renderer draws it.
  let padding: CGFloat
  let overlay: RenderOverlay?
  let onPresented: (Int) -> Void
  let onScale: (CGFloat) -> Void
  @State private var problem: Dialog?
  @Environment(\.workspaceBackgroundOpacity) private var backgroundOpacity

  var body: some View {
    NativeTerminal(frame: frame, dirtyRows: dirtyRows, damageEpoch: damageEpoch, metrics: metrics,
      palette: palette, padding: padding, backgroundOpacity: backgroundOpacity, overlay: overlay, onPresented: onPresented, onScale: onScale) { error, retry, dismiss in
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
  let padding: CGFloat
  let backgroundOpacity: Double
  let overlay: RenderOverlay?
  let onPresented: (Int) -> Void
  let onScale: (CGFloat) -> Void
  let failure: (Error, @escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void

  @MainActor private func update(_ view: TerminalGPUView) {
    view.onFailure = failure
    view.onPresented = onPresented
    view.onScale = onScale
    view.update(frame: frame, dirtyRows: dirtyRows, damageEpoch: damageEpoch, metrics: metrics, palette: palette, overlay: overlay, padding: padding, backgroundOpacity: backgroundOpacity)
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
    /// The margin round the grid, in device pixels. Negative: none drawn.
    var padding: CGFloat
    /// The window's opacity. Below 1 the page is the window's glass.
    var backgroundOpacity: Double
    var overlay: RenderOverlay?
    var transparentBackground: Bool { backgroundOpacity < 1 }
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
  /// The window was ordered out. The swapchain from that generation cannot
  /// be acquired; drawing it blocks this thread inside `nextDrawable`.
  private var orderedIn = false
  /// The window just came forward. Paint waits until the next run-loop turn,
  /// after the order-front that made it visible has returned.
  private var paintHeld = false
  private var resumeQueued = false
  /// One missed acquire recreates the surface. A second miss waits for the
  /// window to come forward again instead of blocking every turn.
  private var acquireGaveUp = false
  private(set) var submittedFrames = 0
  var onFailure: ((Error, @escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?
  var onPresented: ((Int) -> Void)?
  var onScale: ((CGFloat) -> Void)?

  #if os(macOS)
    override func makeBackingLayer() -> CALayer { TimeoutMetalLayer() }
    init() {
      super.init(frame: .zero)
      wantsLayer = true
      for name in [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
        NSWindow.didBecomeKeyNotification,
      ] {
        NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
      }
      NotificationCenter.default.addObserver(self, selector: #selector(resume), name: NSApplication.didUnhideNotification, object: nil)
    }
    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); noteScale(); window == nil ? shutdown() : schedule() }
    override func layout() {
      super.layout()
      noteScale()
      guard window?.isVisible == true else {
        orderedIn = false
        paintHeld = false
        if renderer != nil || initialization != nil { shutdown() }
        return
      }
      guard orderedIn else {
        orderedIn = true
        paintHeld = true
        resume()
        return
      }
      schedule()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); noteScale(); invalidate(); schedule() }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayScale: CGFloat { window?.backingScaleFactor ?? 1 }
    private var drawable: Bool {
      guard let window, window.isVisible, !isHidden, window.isMiniaturized == false,
        !NSApplication.shared.isHidden else { return false }
      return window.occlusionState.contains(.visible)
    }
    @objc private func windowChanged(_ note: Notification) {
      guard let window, (note.object as? NSWindow) === window else { return }
      guard window.isVisible else {
        // The swapchain from a window that has left the screen cannot be
        // acquired. Drop it here, not on the turn that orders the window back.
        orderedIn = false
        paintHeld = false
        if renderer != nil || initialization != nil { shutdown() }
        return
      }
      let cameForward = note.name == NSWindow.didDeminiaturizeNotification
        || note.name == NSWindow.didBecomeKeyNotification
      let visible = window.occlusionState.contains(.visible) || cameForward
      guard visible else { return }
      orderedIn = true
      paintHeld = true
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

  func update(frame: ScreenFrame, dirtyRows: Set<Int>?, damageEpoch: Int, metrics: FontMetrics, palette: Palette, overlay: RenderOverlay?, padding: CGFloat = -1, backgroundOpacity: Double = 1) {
    // Close holds until Retry. A newer frame must not clear that latch.
    if quietDismissal { return }
    let dirty: Set<Int>?
    if let pending {
      dirty = pending.dirty.flatMap { old in dirtyRows.map { old.union($0) } }
    } else { dirty = dirtyRows }
    pending = Pending(frame: frame, dirty: dirty, damageEpoch: damageEpoch, metrics: metrics, palette: palette, padding: padding, backgroundOpacity: backgroundOpacity, overlay: overlay)
    noteScale()
    #if os(macOS)
      if paintHeld { return }
    #endif
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
  /// Paint after this run-loop turn. A window that just came forward has not
  /// committed its layer yet, and acquiring a drawable waits until it has.
  @objc private func resume() {
    guard !resumeQueued else { return }
    resumeQueued = true
    RunLoop.main.perform { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.resumeQueued = false
        self.acquireGaveUp = false
        self.paintHeld = false
        if self.renderer == nil { self.invalidate() }
        self.schedule()
      }
    }
  }

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
    metalLayer.isOpaque = !pending.transparentBackground
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
      // `configure` turns this off, and `nextDrawable` then waits on this
      // thread until a drawable exists. A window that just came forward can
      // already look visible while the compositor has none.
      metalLayer.allowsNextDrawableTimeout = true
      renderer.setFonts(primary: pending.metrics.primary, wide: pending.metrics.wide)
      let fontSize = Float(pending.metrics.size * scale)
      _ = try renderer.measure(size: fontSize)
      let epoch = pending.damageEpoch
      // The host supplies the shared workspace backdrop behind grid and padding.
      // Only default terminal backgrounds become clear; explicit cell colors stay solid.
      let palette = pending.palette.renderPalette(backgroundOpacity: pending.transparentBackground ? 0 : 1)
      // A program's own backgrounds sit on the glass at the window's opacity.
      renderer.setGridPadding(Float(pending.padding))
      renderer.setCellBackgroundOpacity(Float(pending.transparentBackground ? pending.backgroundOpacity : 1))
      let presented = try renderer.draw(frame: pending.frame, palette: palette, overlay: pending.overlay,
        fontSize: fontSize, dirtyRows: pending.dirty.map { $0.sorted().map(UInt32.init) })
      if notePresent(presented, epoch: epoch) {
        acquireGaveUp = false
      } else if !acquireGaveUp {
        // Retrying inside this turn calls `nextDrawable` again before the
        // compositor can make one, so the timeout never ends.
        acquireGaveUp = true
        shutdown()
        RunLoop.main.perform { [weak self] in
          MainActor.assumeIsolated { self?.schedule() }
        }
      }
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
  func renderPalette(backgroundOpacity: Double = 1) -> RenderPalette {
    let color = background.renderColor
    return RenderPalette(
      background: RenderColor(red: color.red, green: color.green, blue: color.blue, alpha: Float(backgroundOpacity)),
      foreground: foreground.renderColor, cursor: cursor.renderColor, ansi: (normal + bright).map(\.renderColor))
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
