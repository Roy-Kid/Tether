import QuartzCore
import SwiftUI
import Testing
import Tether
@testable import TetherUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite("Native shared-renderer lifecycle", .serialized)
struct NativeSurfaceTests {
  private func frame() -> ScreenFrame {
    ScreenFrame(columns: 12, rows: 2, cursorRow: 0, cursorColumn: 0, cursorShape: .block,
      cursorVisible: true, alternateScreen: false, mouse: .off, viewportOffset: 0,
      historyLines: 0, title: "", lines: [ScreenRow(runs: []), ScreenRow(runs: [])])
  }

  private func waitForFrame(_ view: TerminalGPUView, after count: Int) async throws {
    // A correctness timeout, not a frame-time performance assertion.
    for _ in 0..<200 {
      if view.submittedFrames > count { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("native host never submitted its frame")
  }

  #if os(macOS)
  @Test("attach, hidden updates, resize, detach and reattach")
  func lifetime() async throws {
    TerminalFonts.prepare()
    let view = TerminalGPUView()
    var failures: [String] = []
    view.onFailure = { error, _, _ in failures.append(error.localizedDescription) }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    defer { view.shutdown(); window.orderOut(nil); window.contentView = nil }
    let metrics = FontMetrics(size: 13)
    view.update(frame: frame(), dirtyRows: [], damageEpoch: 0, metrics: metrics, palette: .dark, overlay: nil)
    // A command-line test process often never receives the visible occlusion
    // bit. The host must then submit nothing. A window the server calls
    // visible still has to attach, ignore hidden updates, resize and reattach.
    guard window.occlusionState.contains(.visible) else {
      try await Task.sleep(for: .milliseconds(200))
      #expect(view.submittedFrames == 0)
      view.isHidden = true
      view.update(frame: frame(), dirtyRows: [], damageEpoch: 0, metrics: metrics, palette: .light, overlay: nil)
      try await Task.sleep(for: .milliseconds(100))
      #expect(view.submittedFrames == 0)
      view.shutdown()
      view.shutdown()
      view.isHidden = false
      view.frame.size = CGSize(width: 220, height: 80)
      view.update(frame: frame(), dirtyRows: [], damageEpoch: 1, metrics: metrics, palette: .dark, overlay: nil)
      try await Task.sleep(for: .milliseconds(100))
      #expect(view.submittedFrames == 0)
      view.shutdown()
      view.update(frame: frame(), dirtyRows: [], damageEpoch: 2, metrics: metrics, palette: .dark, overlay: nil)
      try await Task.sleep(for: .milliseconds(100))
      #expect(view.submittedFrames == 0)
      var acknowledged = 0
      view.onPresented = { _ in acknowledged += 1 }
      view.dismissFromDialog()
      view.update(frame: frame(), dirtyRows: [0], damageEpoch: 3, metrics: metrics, palette: .light, overlay: nil)
      #expect(view.holdsClosedDismissal)
      #expect(view.notePresent(false, epoch: 3) == false)
      #expect(acknowledged == 0)
      #expect(view.submittedFrames == 0)
      #expect(failures.isEmpty, "\(failures)")
      return
    }
    try await waitForFrame(view, after: 0)
    let before = view.submittedFrames
    view.isHidden = true
    view.update(frame: frame(), dirtyRows: [], damageEpoch: 0, metrics: metrics, palette: .light, overlay: nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(view.submittedFrames == before)
    view.isHidden = false
    view.frame.size = CGSize(width: 220, height: 80)
    view.update(frame: frame(), dirtyRows: [], damageEpoch: 0, metrics: metrics, palette: .light, overlay: nil)
    try await waitForFrame(view, after: before)
    view.shutdown()
    view.shutdown()
    let closed = view.submittedFrames
    view.update(frame: frame(), dirtyRows: [], damageEpoch: 0, metrics: metrics, palette: .dark, overlay: nil)
    try await waitForFrame(view, after: closed)
    #expect(failures.isEmpty, "\(failures)")
  }

  #else
  @Test("an iOS Metal layer can attach, draw, close and attach again")
  func layerLifetime() async throws {
    TerminalFonts.prepare()
    let layer = CAMetalLayer()
    defer { _fixLifetime(layer) }
    layer.contentsScale = 3
    layer.drawableSize = CGSize(width: 900, height: 300)
    for _ in 0..<3 {
      let renderer = try TerminalRenderer(metalLayer: Unmanaged.passUnretained(layer).toOpaque())
      try await renderer.initialize(width: 900, height: 300)
      renderer.setFonts(primary: TerminalFonts.resolvedPrimary(TerminalFonts.primary), wide: TerminalFonts.wide)
      _ = try renderer.measure(size: 39)
      _ = try renderer.draw(frame: frame(), palette: Palette.dark.renderPalette(), fontSize: 39, dirtyRows: [])
      renderer.close()
      renderer.close()
    }
  }
  #endif

  @Test("closing async initialization cannot revive the surface")
  func cancellation() async throws {
    let layer = CAMetalLayer()
    defer { _fixLifetime(layer) }
    let renderer = try TerminalRenderer(metalLayer: Unmanaged.passUnretained(layer).toOpaque())
    let initialization = Task { try? await renderer.initialize(width: 100, height: 100) }
    await Task.yield()
    renderer.close()
    await initialization.value
    #expect(throws: RenderingError.self) {
      _ = try renderer.draw(frame: frame(), palette: Palette.dark.renderPalette(), fontSize: 13)
    }
  }

}
