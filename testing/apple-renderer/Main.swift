import Darwin
import AppKit
import CoreText
import Foundation
import ImageIO
import Metal
import SwiftUI
import Tether

@main
@MainActor
struct Compare {
  static func main() async throws {
    let mode = CommandLine.arguments[1]
    let evidence = URL(fileURLWithPath: CommandLine.arguments[2])
    memory("start")
    let points = FontMetrics(size: 13)
    if mode == "wgpu" {
      let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
      let tags = CTFontCopyAvailableTables(base, [])!
      let tables: [RenderFontTable] = (0..<CFArrayGetCount(tags)).compactMap { index in
        let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tags, index)))
        return CTFontCopyTable(base, tag, []).map { RenderFontTable(tag: tag, data: $0 as Data) }
      }
      _ = try RenderingFonts.register(tables: tables, familyAlias: "evaluation-system")
    }
    memory("fonts-ready")
    var results: [[String: Any]] = []
    for (columns, rows, shape) in [(80,24,"prose"), (120,40,"highlighted"), (200,60,"highlighted"), (120,40,"per-cell")] {
      let width = Int(points.cellWidth) * columns * 2
      let height = Int(points.lineHeight) * rows * 2
      var times: [Double] = []
      var cpuTimes: [Double] = []
      if mode == "metal" {
        let device = MTLCreateSystemDefaultDevice()!
        let view = TerminalMetalView(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = device.makeTexture(descriptor: descriptor)!
        for tick in 0..<23 {
          let input = frame(columns: columns, rows: rows, shape: shape, tick: tick)
          let start = ContinuousClock.now
          view.present(frame: input, dirtyRows: nil, metrics: points, palette: .dark)
          let command = view.submitForEvaluation(target: target, points: SIMD2(Float(width/2), Float(height/2)))!
          if tick >= 3 { cpuTimes.append(milliseconds(start.duration(to: .now))) }
          completeSynchronously(command)
          if tick >= 3 { times.append(milliseconds(start.duration(to: .now))) }
        }
      } else {
        let renderer = try await TerminalRenderer.offscreen(width: UInt32(width), height: UInt32(height))
        renderer.setFonts(primary: "evaluation-system", wide: "PingFang SC")
        _ = try renderer.measure(size: 26)
        memory("surface-ready-\(columns)x\(rows)")
        for tick in 0..<23 {
          let input = frame(columns: columns, rows: rows, shape: shape, tick: tick)
          let start = ContinuousClock.now
          _ = try renderer.draw(frame: input, palette: renderPalette(), fontSize: 26)
          if tick >= 3 { cpuTimes.append(milliseconds(start.duration(to: .now))) }
          try renderer.waitIdle()
          if tick >= 3 { times.append(milliseconds(start.duration(to: .now))) }
        }
        memory("draws-complete-\(columns)x\(rows)")
        renderer.close()
        memory("surface-closed-\(columns)x\(rows)")
      }
      times.sort()
      cpuTimes.sort()
      results.append(["columns": columns, "rows": rows, "shape": shape, "samples": times.count,
        "p50_ms": times[times.count/2], "p95_ms": times[Int(Double(times.count-1)*0.95)],
        "cpu_submit_p50_ms": cpuTimes[cpuTimes.count/2], "cpu_submit_p95_ms": cpuTimes[Int(Double(cpuTimes.count-1)*0.95)],
        "physical_width": width, "physical_height": height])
    }
    let fonts = frame(columns: 40, rows: 2, shape: "fonts", tick: 0)
    var pixels: Data
    if mode == "metal" {
      let view = TerminalMetalView(device: MTLCreateSystemDefaultDevice()!)
      view.present(frame: fonts, dirtyRows: nil, metrics: points, palette: .dark)
      var bytes = view.snapshot(width: 400, height: 50, scale: 2)!.bytes
      for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i+2) }
      pixels = Data(bytes)
    } else {
      let renderer = try await TerminalRenderer.offscreen(width: 800, height: 100)
      renderer.setFonts(primary: "evaluation-system", wide: "PingFang SC")
      _ = try renderer.measure(size: 26)
      _ = try renderer.draw(frame: fonts, palette: renderPalette(), fontSize: 26)
      pixels = try renderer.readPixels()
      renderer.close()
    }
    let image = CGImage(width: 800, height: 100, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(evidence.appending(path: mode + "-comparison.png") as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("image export") }
    memory("font-grid-complete")
    let result: [String: Any] = ["renderer": mode, "font_size_physical_px": 26, "samples_per_scenario": 20,
      "measurement": "offscreen frame update plus GPU completion; screenshots/readback are separate; not presentation latency",
      "observations": results]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
  }

  // This standalone measurement deliberately waits outside the CPU span,
  // matching the explicit completion fence used by the shared renderer.
  static func completeSynchronously(_ command: MTLCommandBuffer) { command.waitUntilCompleted() }

  static func memory(_ phase: String) {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    if result == KERN_SUCCESS {
      FileHandle.standardError.write(Data("memory_phase \(phase) resident_bytes \(info.resident_size)\n".utf8))
    }
  }

  static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15
  }
  static func frame(columns: Int, rows: Int, shape: String, tick: Int) -> ScreenFrame {
    let lines = (0..<rows).map { row -> ScreenRow in
      let style = CellStyle(foreground: .named(name: .foreground), background: .named(name: .background),
        underline: .none, underlineColor: nil, bold: false, dim: false, italic: false, strikethrough: false, inverse: false, hidden: false)
      if shape == "fonts" {
        let segments: [(String, UInt32)] = [("Hello ",6),("中文",4),(" ",1),("e\u{301}",1),(" ",1),("👩‍💻",2),(" ┌─┐ éΩЖ ∑",10)]
        return ScreenRow(runs: segments.map { StyledRun(text: $0.0, columns: $0.1, style: style) })
      }
      let count = shape == "per-cell" ? columns : shape == "highlighted" ? 6 : 1
      return ScreenRow(runs: (0..<count).map { part in
        let width = (part+1)*columns/count - part*columns/count
        let color = CellColor.indexed(index: UInt8(16 + part%216))
        let style = CellStyle(foreground: color, background: .named(name: .background), underline: .none,
          underlineColor: nil, bold: part%3 == 1, dim: false, italic: part%3 == 2, strikethrough: false, inverse: false, hidden: false)
        return StyledRun(text: String(repeating: String(UnicodeScalar(65+(row+tick)%26)!), count: width), columns: UInt32(width), style: style)
      })
    }
    return ScreenFrame(columns: UInt32(columns), rows: UInt32(rows), cursorRow: 0, cursorColumn: 0,
      cursorShape: .hidden, cursorVisible: false, alternateScreen: false, mouse: .off,
      viewportOffset: 0, historyLines: 0, title: "", lines: lines)
  }
  static func renderPalette() -> RenderPalette {
    func rgba(_ color: Color) -> RenderColor {
      let native = NSColor(color).usingColorSpace(.sRGB)!
      return RenderColor(red: Float(native.redComponent), green: Float(native.greenComponent),
        blue: Float(native.blueComponent), alpha: Float(native.alphaComponent))
    }
    let palette = Palette.dark
    return RenderPalette(background: rgba(palette.background), foreground: rgba(palette.foreground),
      cursor: rgba(palette.cursor), ansi: (palette.normal + palette.bright).map(rgba))
  }
}
