import CoreText
import CoreGraphics
import ImageIO
import Foundation
import Tether
import Testing
@testable import TetherUI

@MainActor
@Suite("Shared wgpu rendering", .serialized)
struct SharedRenderTests {
  private func screen(_ text: String? = nil, cursor: CaretShape = .hidden, hiddenBackground: CellColor = .named(name: .red)) -> ScreenFrame {
    func style(bold: Bool = false, italic: Bool = false, lines: Bool = false, hidden: Bool = false) -> CellStyle {
      CellStyle(foreground: .named(name: .foreground), background: hidden ? hiddenBackground : .named(name: .background),
        underline: lines ? .single : .none, underlineColor: lines ? .named(name: .cyan) : nil, bold: bold, dim: false,
        italic: italic, strikethrough: lines, inverse: false, hidden: hidden)
    }
    let segments: [(String, UInt32)] = text.map { [($0, UInt32($0.count))] } ?? [
      ("Hello ", 6), ("中文", 4), (" ", 1), ("e\u{301}", 1), (" ", 1), ("👩‍💻", 2),
      (" ", 1), ("┌─┐", 3), (" éΩЖ ∑", 6),
    ]
    var runs = segments.map { StyledRun(text: $0.0, columns: $0.1, style: style()) }
    let used = segments.reduce(UInt32(0)) { $0 + $1.1 }
    runs.append(StyledRun(text: String(repeating: " ", count: Int(39 - used)) + "|", columns: 40 - used, style: style()))
    return ScreenFrame(columns: 40, rows: 2, cursorRow: 1, cursorColumn: 0, cursorShape: cursor,
      cursorVisible: cursor != .hidden, alternateScreen: false, mouse: .off, viewportOffset: 0,
      historyLines: 0, title: "", lines: [ScreenRow(runs: runs), ScreenRow(runs: [
        StyledRun(text: "Bold ", columns: 5, style: style(bold: true)),
        StyledRun(text: "Italic ", columns: 7, style: style(italic: true)),
        StyledRun(text: "Lines ", columns: 6, style: style(lines: true)),
        StyledRun(text: "secret", columns: 6, style: style(hidden: true)),
      ])])
  }

  @Test("actual pixels cover initial empty damage, cursor changes, restyling and shrink")
  func pixels() async throws {
    TerminalFonts.prepare()
    #expect(TerminalFonts.failure == nil)
    #expect(!TerminalFonts.systemFaces.isEmpty, "the native default font must actually be loaded")
    let renderer = try await TerminalRenderer.offscreen(width: 800, height: 100)
    defer { renderer.close() }
    renderer.setFonts(primary: TerminalFonts.resolvedPrimary(TerminalFonts.primary), wide: TerminalFonts.wide)
    let metrics = try renderer.measure(size: 26)
    let frame = screen()
    _ = try renderer.draw(frame: frame, palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [])
    let first = try renderer.readPixels()
    #expect(first.count == 800 * 100 * 4)
    let colors = Set(stride(from: 0, to: first.count, by: 4).map { first[$0..<$0+3].map(String.init).joined(separator: ",") })
    #expect(colors.count > 5, "text must produce visible ink")
    let background = first[(first.count - 4)..<first.count]
    let lastX = Int(metrics.cellWidth * 39)
    let lastRight = min(800, Int(metrics.cellWidth * 40))
    let lastColumnHasInk = (0..<Int(metrics.lineHeight)).contains { y in
      (lastX..<lastRight).contains { x in first[(y * 800 + x) * 4..<(y * 800 + x) * 4 + 4] != background }
    }
    #expect(lastColumnHasInk, "the last terminal column must actually be drawn")
    let secretIndex = (Int(metrics.lineHeight * 1.5) * 800 + Int(metrics.cellWidth * 20)) * 4
    #expect(Array(first[secretIndex..<secretIndex+4]) == [255, 59, 48, 255], "hidden text keeps its opaque cell background")

    if let directory = ProcessInfo.processInfo.environment["TETHER_RENDER_EVIDENCE_DIR"] {
      let url = URL(fileURLWithPath: directory).appending(path: "shared-font-grid.png")
      let provider = try #require(CGDataProvider(data: first as CFData))
      let image = try #require(CGImage(width: 800, height: 100, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      #expect(CGImageDestinationFinalize(destination))
    }

    #expect(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 255 }, "opaque layer")
    // Changing only presentation alpha must redraw an idle terminal. Text and
    // program-painted backgrounds remain opaque over the native window blur.
    let remote = Palette.dark.remoteForm
    _ = try renderer.draw(frame: frame, palette: Palette.dark.renderPalette(backgroundOpacity: 0), fontSize: 26, dirtyRows: [])
    let transparent = try renderer.readPixels()
    #expect(Array(transparent.suffix(4)) == [0, 0, 0, 0],
      "transparent pixels must not add a grey or colored wash during native compositing")
    #expect(Array(transparent[secretIndex..<secretIndex+4]) == [255, 59, 48, 255], "explicit cell background stays solid")
    #expect(stride(from: 3, to: transparent.count, by: 4).contains { transparent[$0] == 255 }, "glyph ink remains opaque")
    // Core Animation consumes premultiplied sRGB. Check antialiased text,
    // not just fully opaque color blocks or the fully transparent clear.
    let textWidth = Int(metrics.cellWidth * 6)
    let textHeight = Int(metrics.lineHeight)
    let edgePixels = (0..<textHeight).flatMap { y in
      (0..<textWidth).map { x in (y * 800 + x) * 4 }
    }.filter { transparent[$0 + 3] > 32 && transparent[$0 + 3] < 224 }
    #expect(!edgePixels.isEmpty)
    #expect(edgePixels.allSatisfy { index in
      (0..<3).allSatisfy { Int(transparent[index + $0]) <= Int(transparent[index + 3]) + 1 }
    }, "translucent glyph edges must not add a bright color fringe to the native backdrop")
    let ink = [remote.foreground.red, remote.foreground.green, remote.foreground.blue]
    #expect(edgePixels.allSatisfy { index in
      let alpha = Int(transparent[index + 3])
      return (0..<3).allSatisfy { channel in
        abs(Int(transparent[index + channel]) * 255 - Int(ink[channel]) * alpha) <= 510
      }
    }, "antialiased text must retain the palette's sRGB hue and brightness after unpremultiplication")
    #expect(Palette.dark.remoteForm == remote, "window presentation never changes remote color responses")
    _ = try renderer.draw(frame: frame, palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [])
    #expect(try renderer.readPixels() == first, "turning glass off restores the opaque frame")
    for palette in [Palette.dark, .light, .softDark, .softLight] {
      let expected = palette.remoteForm.background
      _ = try renderer.draw(frame: screen(hiddenBackground: .rgb(red: 17, green: 133, blue: 211)),
        palette: palette.renderPalette(), fontSize: 26, dirtyRows: [1])
      let pixels = try renderer.readPixels()
      #expect(Array(pixels.suffix(4)) == [expected.red, expected.green, expected.blue, 255],
        "rendered background must match the sRGB color reported to terminal programs")
      #expect(Array(pixels[secretIndex..<secretIndex+4]) == [17, 133, 211, 255],
        "true-color output must keep its exact RGB values in every theme")
    }
    _ = try renderer.draw(frame: frame, palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [])

    _ = try renderer.draw(frame: screen(cursor: .block), palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [])
    #expect(try renderer.readPixels() != first)
    _ = try renderer.draw(frame: frame, palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [])
    #expect(try renderer.readPixels() == first)
    let overlay = RenderOverlay(selection: RenderSelection(anchorColumn: 1, anchorRow: 0, focusColumn: 3, focusRow: 0),
      linkUnderlines: [RenderLinkUnderline(row: 0, start: 5, end: 10, confirmed: false)],
      selectionColor: RenderColor(red: 0, green: 0.5, blue: 1, alpha: 0.2),
      linkColor: RenderColor(red: 0, green: 0.5, blue: 1, alpha: 1))
    _ = try renderer.draw(frame: frame, palette: Palette.dark.renderPalette(), overlay: overlay, fontSize: 26, dirtyRows: [])
    #expect(try renderer.readPixels() != first, "pointer marks must redraw without cell damage")
    _ = try renderer.draw(frame: frame, palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [])
    #expect(try renderer.readPixels() == first, "clearing marks must restore the original pixels")
    _ = try renderer.draw(frame: screen("Changed"), palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [0])
    #expect(try renderer.readPixels() != first)
    _ = try renderer.draw(frame: frame, palette: Palette.light.renderPalette(), fontSize: 26, dirtyRows: [])
    #expect(try renderer.readPixels() != first)
    renderer.resize(width: 400, height: 80)
    _ = try renderer.draw(frame: screen(""), palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [])
    #expect(try renderer.readPixels().count == 400 * 80 * 4)
    renderer.close()
    renderer.close()
    #expect(throws: RenderingError.self) {
      _ = try renderer.draw(frame: frame, palette: Palette.dark.renderPalette(), fontSize: 26)
    }
  }

  @Test("native and render metrics agree at each display scale")
  func metricsAgree() async throws {
    TerminalFonts.prepare()
    let renderer = try await TerminalRenderer.offscreen(width: 100, height: 100)
    defer { renderer.close() }
    renderer.setFonts(primary: TerminalFonts.resolvedPrimary(TerminalFonts.primary), wide: TerminalFonts.wide)
    for scale in [1.0, 2.0, 3.0] {
      let native = FontMetrics(size: 13, scale: scale)
      let shared = try renderer.measure(size: Float(13 * scale))
      #expect(abs(native.cellWidth * scale - Double(shared.cellWidth)) < 0.001)
      #expect(abs(native.lineHeight * scale - Double(shared.lineHeight)) < 0.001)
    }
  }

  @Test("invalid imports preserve the catalogue and selected font")
  func invalidFont() {
    let before = TerminalFonts.faces()
    #expect(throws: RenderingError.self) { try RenderingFonts.register(Data("invalid font".utf8)) }
    #expect(TerminalFonts.faces() == before)
  }
  @Test("font import deduplicates faces and reloads stable identities")
  func importAndReload() throws {
    TerminalFonts.prepare()
    let collection = CTFontCollectionCreateFromAvailableFonts(nil)
    let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
    let source = try #require(descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL }.first {
      let size = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
      return size < 5 * 1024 * 1024
    })
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try TerminalFonts.importFont(source, into: directory)
    let second = try TerminalFonts.importFont(source, into: directory)
    #expect(first == second)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(try RenderingFonts.register(Data(contentsOf: files[0])) == first)
    #expect(first.allSatisfy { face in RenderingFonts.faces().filter { $0.id == face.id }.count == 1 })
  }

  @Test("new CJK glyphs remain visible after atlas churn")
  func atlasChurn() async throws {
    TerminalFonts.prepare()
    let renderer = try await TerminalRenderer.offscreen(width: 800, height: 100)
    defer { renderer.close() }
    renderer.setFonts(primary: TerminalFonts.resolvedPrimary(TerminalFonts.primary), wide: TerminalFonts.wide)
    _ = try renderer.measure(size: 26)
    var latest = screen()
    for batch in 0..<100 {
      let text = (0..<20).compactMap { UnicodeScalar(0x4E00 + batch * 20 + $0) }.map(String.init).joined()
      let style = screen().lines[0].runs[0].style
      latest = ScreenFrame(columns: 40, rows: 1, cursorRow: 0, cursorColumn: 0,
        cursorShape: .hidden, cursorVisible: false, alternateScreen: false, mouse: .off,
        viewportOffset: 0, historyLines: 0, title: "", lines: [ScreenRow(runs: [StyledRun(text: text, columns: 40, style: style)])])
      _ = try renderer.draw(frame: latest, palette: Palette.dark.renderPalette(), fontSize: 26, dirtyRows: [0])
    }
    let image = try renderer.readPixels()
    let fresh = try await TerminalRenderer.offscreen(width: 800, height: 100)
    defer { fresh.close() }
    fresh.setFonts(primary: TerminalFonts.resolvedPrimary(TerminalFonts.primary), wide: TerminalFonts.wide)
    _ = try fresh.measure(size: 26)
    _ = try fresh.draw(frame: latest, palette: Palette.dark.renderPalette(), fontSize: 26)
    #expect(try fresh.readPixels() == image, "eviction must not drop the current frame's glyphs")
  }

}
