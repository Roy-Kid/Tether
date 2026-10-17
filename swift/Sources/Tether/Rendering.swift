import Foundation
import TetherFFIBindings

public typealias RenderColor = TetherFFIBindings.RgbaDto
public typealias RenderPalette = TetherFFIBindings.PaletteDto
public typealias RenderOverlay = TetherFFIBindings.OverlayDto
public typealias RenderSelection = TetherFFIBindings.SelectionDto
public typealias RenderLinkUnderline = TetherFFIBindings.LinkUnderlineDto
public typealias RenderFontMetrics = TetherFFIBindings.FontMetricsDto
public typealias RenderFontTable = TetherFFIBindings.FontTableDto
public typealias TerminalFontFace = TetherFFIBindings.FontFaceDto

public typealias RenderFailure = TetherFFIBindings.RenderFailure

public struct RenderingError: Error, LocalizedError, Sendable {
  public let cause: String
  public init(cause: String) { self.cause = cause }
  /// One mapping for each GPU failure. The generated description reflects the
  /// enum; a dialog needs the cause the renderer reported.
  public init(_ failure: RenderFailure) {
    switch failure {
    case .NoAdapter: cause = "No suitable GPU adapter"
    case .NoDevice(let cause): self.cause = "No suitable GPU device: \(cause)"
    case .Surface(let cause): self.cause = "Surface: \(cause)"
    case .Font(let cause): self.cause = "Font: \(cause)"
    }
  }
  public var errorDescription: String? { cause }
}

private func renderingCall<T>(_ body: () throws -> T) throws -> T {
  do { return try body() }
  catch let error as RenderingError { throw error }
  catch let error as RenderFailure { throw RenderingError(error) }
  catch { throw RenderingError(cause: String(describing: error)) }
}

/// GPU-independent catalogue used by native font discovery and file pickers.
public enum RenderingFonts {
  public static func faces() -> [TerminalFontFace] { renderFontFaces() }
  public static func registerFile(_ path: String, familyAlias: String? = nil) throws -> [TerminalFontFace] {
    try renderingCall { try renderRegisterFontFile(path: path, familyAlias: familyAlias) }
  }
  public static func register(_ data: Data) throws -> [TerminalFontFace] {
    try renderingCall { try renderRegisterFont(data: data) }
  }
  public static func register(tables: [RenderFontTable], familyAlias: String) throws -> [TerminalFontFace] {
    try renderingCall { try renderRegisterFontTables(tables: tables, familyAlias: familyAlias) }
  }
  public static func measure(size: Float, primary: String, wide: String) throws -> RenderFontMetrics {
    try renderingCall { try renderMeasureFonts(size: size, primary: primary, wide: wide) }
  }
}

/// The host owns its native layer. Attach on the main actor, await device
/// initialization, serialize updates, and close before destroying that layer.
@MainActor
public final class TerminalRenderer {
  private let inner: TetherFFIBindings.RenderSurface
  private var closed = false
  private var ready = false

  public init(metalLayer: UnsafeMutableRawPointer) throws {
    inner = try renderingCall {
      try TetherFFIBindings.RenderSurface.fromMetalLayer(layer: UInt64(UInt(bitPattern: metalLayer)))
    }
  }
  private init(_ inner: TetherFFIBindings.RenderSurface) { self.inner = inner; ready = true }

  public static func offscreen(width: UInt32, height: UInt32) async throws -> TerminalRenderer {
    do { return TerminalRenderer(try await TetherFFIBindings.RenderSurface.offscreen(width: width, height: height)) }
    catch let error as RenderFailure { throw RenderingError(error) }
    catch { throw RenderingError(cause: String(describing: error)) }
  }

  public func initialize(width: UInt32, height: UInt32) async throws {
    do { try await inner.initialize(width: width, height: height) }
    catch let error as RenderFailure { throw RenderingError(error) }
    catch let error as RenderingError { throw error }
    catch { throw RenderingError(cause: String(describing: error)) }
    guard !closed else { throw RenderingError(cause: "Surface closed during initialization") }
    ready = true
  }
  public func setFonts(primary: String, wide: String) { inner.setFonts(primary: primary, wide: wide) }
  public func measure(size: Float) throws -> RenderFontMetrics {
    guard ready, !closed else { throw RenderingError(cause: "Surface not ready or closed") }
    return try renderingCall { try inner.measure(size: size) }
  }
  public func resize(width: UInt32, height: UInt32) { inner.resize(width: width, height: height) }
  /// `true` when a frame was presented, including an offscreen target.
  /// `false` when the compositor skipped the acquire: keep the damage and draw again.
  public func draw(frame: ScreenFrame, palette: RenderPalette, overlay: RenderOverlay? = nil,
                   fontSize: Float, dirtyRows: [UInt32]? = nil) throws -> Bool {
    guard !closed else { throw RenderingError(cause: "Surface closed") }
    return try renderingCall {
      try inner.drawUpdate(frame: frame, palette: palette, overlay: overlay, fontSize: fontSize, dirtyRows: dirtyRows)
    }
  }
  public func readPixels() throws -> Data { try renderingCall { try inner.readPixels() } }
  public func waitIdle() throws { try renderingCall { try inner.waitIdle() } }
  public func close() {
    guard !closed else { return }
    closed = true
    inner.close()
  }
  isolated deinit { inner.close() }
}
