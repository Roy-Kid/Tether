#if os(macOS)
  import SwiftUI
  import Tether
  import Testing

  @testable import TetherUI

  /// What one frame costs to draw.
  ///
  /// The frontend draws terminal frames with a SwiftUI `Canvas`. The
  /// specification says the GPU text stack is chosen by measurement (§23,
  /// Phase 4) and that optimisation follows profiling (§20) — and for a while
  /// this drew every frame without anyone having measured one. This is the
  /// measurement.
  ///
  /// It is a *shape*, not a benchmark: the absolute numbers belong to the
  /// machine that ran them. What the assertion defends is the order of magnitude —
  /// a change that makes a frame ten times more expensive is a change that
  /// made the terminal unusable on the slowest machine it ships to, and that
  /// must fail here rather than in someone's hands.
  ///
  /// Print the table with:
  /// `swift test -c release --package-path app/Packages/TetherFrontend --filter RenderCost`
  @Suite("Render cost")
  @MainActor
  struct RenderCostTests {
    /// A default window, a large one, and a full-screen 6K display.
    static let sizes: [(columns: UInt32, rows: UInt32)] = [
      (80, 24), (120, 40), (200, 60), (400, 100),
    ]

    /// What a screen a person actually has in front of them may cost.
    ///
    /// Generous on purpose — well past a 60Hz frame — because a CI machine is
    /// slower than a laptop and a performance test that flakes gets deleted
    /// rather than fixed. What this catches is an order of magnitude, not a
    /// percent.
    static let ordinaryCeiling: Duration = .milliseconds(60)

    /// The worst case is measured as a *rate*, because its absolute number is
    /// already over any frame budget there is: at the time of writing, a
    /// screen where every cell carries its own colour costs 0.9s to draw at
    /// 400x100. Asserting the number it has today would be
    /// asserting the problem. Asserting the cost per run catches the thing
    /// that can still be defended — that drawing one more run stays as cheap
    /// as it is.
    static let ceilingPerRun: Duration = .microseconds(100)

    @Test("a frame draws in a frame's worth of time")
    func drawCost() throws {
      print("\nrender cost — SwiftUI Canvas, \(ProcessInfo.processInfo.processorCount) cores")
      print("shape        size        runs     draw          per run")

      for shape in Shape.allCases {
        for size in Self.sizes {
          let frame = shape.frame(columns: size.columns, rows: size.rows)
          let runs = frame.lines.reduce(0) { $0 + $1.runs.count }
          let measured = try Self.draw(frame)
          let perRun = measured / runs

          print(
            "\(shape.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) "
              + "\("\(size.columns)x\(size.rows)".padding(toLength: 11, withPad: " ", startingAt: 0))"
              + "\("\(runs)".padding(toLength: 8, withPad: " ", startingAt: 0)) "
              + "\("\(measured)".padding(toLength: 13, withPad: " ", startingAt: 0)) \(perRun)")

          let where_ = "\(shape.rawValue) at \(size.columns)x\(size.rows)"
          if shape == .worstCase {
            #expect(
              perRun < Self.ceilingPerRun,
              "\(where_): \(perRun) per run, past the \(Self.ceilingPerRun) ceiling")
          } else {
            #expect(
              measured < Self.ordinaryCeiling,
              "\(where_): \(measured), past the \(Self.ordinaryCeiling) ceiling")
          }
        }
      }
    }

    /// Rasterises the view the app draws, the way the app draws it.
    ///
    /// A new renderer per frame on purpose: reusing one would measure
    /// SwiftUI's cache rather than the drawing, and a terminal's next frame is
    /// never the same as its last.
    ///
    /// `ImageRenderer` is not the app's presentation path — it rasterises to
    /// a `CGImage` instead of handing a layer to the compositor — but the work
    /// that dominates is the same on both: resolving and drawing one
    /// attributed string per run. It is measurable without a window server,
    /// which is what makes it a number CI can keep.
    static func draw(_ frame: ScreenFrame, iterations: Int = 5) throws -> Duration {
      let metrics = FontMetrics(size: 13)
      var samples: [Duration] = []

      for iteration in 0...iterations {
        // Release each raster before the next sample. Large Retina frames
        // otherwise accumulate autoreleased CoreGraphics objects throughout
        // this synchronous test, measuring memory pressure as rendering cost.
        let elapsed = try autoreleasepool {
          let view = TerminalView(frame: frame, metrics: metrics, palette: .dark)
          let renderer = ImageRenderer(content: view)
          renderer.proposedSize = ProposedViewSize(
            width: metrics.cellWidth * CGFloat(frame.columns),
            height: metrics.lineHeight * CGFloat(frame.rows))
          renderer.scale = 2

          let started = ContinuousClock.now
          let image = renderer.cgImage
          let elapsed = ContinuousClock.now - started
          _ = try #require(image)
          return elapsed
        }
        // Warm the font/raster caches, then use the median to avoid counting
        // an isolated shared-runner scheduling pause as a rendering regression.
        if iteration > 0 { samples.append(elapsed) }
      }
      return samples.sorted()[samples.count / 2]
    }

    /// The three screens worth measuring.
    enum Shape: String, CaseIterable {
      /// What a shell looks like: long stretches of one style.
      case prose
      /// What a syntax-highlighted editor looks like: a few runs per line.
      case highlighted
      /// Every cell its own colour — one run per cell, which is the most a
      /// screen can carry. `btop` and an image viewer both approach it.
      case worstCase = "worst case"

      func frame(columns: UInt32, rows: UInt32) -> ScreenFrame {
        let lines = (0..<rows).map { row in ScreenRow(runs: runs(row: row, columns: columns)) }
        return ScreenFrame(
          columns: columns, rows: rows, cursorRow: rows / 2, cursorColumn: columns / 3,
          cursorShape: .block, cursorVisible: true, alternateScreen: false,
          viewportOffset: 0, historyLines: 0, title: "render cost", lines: lines)
      }

      private func runs(row: UInt32, columns: UInt32) -> [StyledRun] {
        switch self {
        case .prose:
          let text = String(
            repeating: "the quick brown fox jumps over the lazy dog ",
            count: Int(columns) / 44 + 1)
          return [StyledRun(text: String(text.prefix(Int(columns))), columns: columns, style: plain)]

        case .highlighted:
          // Six runs a line, which is what a line of coloured source or a
          // `git diff` produces.
          let width = max(1, Int(columns) / 6)
          return (0..<6).map { index in
            StyledRun(
              text: String(repeating: "abcdefghij", count: width / 10 + 1).prefix(width).description,
              columns: UInt32(width),
              style: styled(index: index, row: row))
          }

        case .worstCase:
          return (0..<columns).map { column in
            StyledRun(text: "#", columns: 1, style: styled(index: column, row: row))
          }
        }
      }

      private var plain: CellStyle {
        CellStyle(
          foreground: .named(name: .foreground), background: .named(name: .background),
          underline: .none, underlineColor: nil, bold: false, dim: false, italic: false,
          strikethrough: false, inverse: false, hidden: false)
      }

      private func styled(index: UInt32, row: UInt32) -> CellStyle {
        CellStyle(
          foreground: .rgb(
            red: UInt8((row &* 7) % 256), green: UInt8((index &* 11) % 256),
            blue: UInt8((row &+ index) % 256)),
          background: index % 3 == 0 ? .named(name: .background) : .indexed(index: 236),
          underline: index % 5 == 0 ? .single : .none, underlineColor: nil,
          bold: index % 2 == 0, dim: false, italic: index % 7 == 0,
          strikethrough: false, inverse: false, hidden: false)
      }
    }
  }
#endif
