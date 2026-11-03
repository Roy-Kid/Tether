import Testing
@testable import TetherUI

@MainActor
@Suite("Wide character font")
struct WideFontTests {
  @Test("the system choice names a font this platform can draw")
  func systemChoice() {
    #if os(iOS)
      // iOS ships PingFang with `hvgl` outlines only, which the renderer
      // cannot paint: every Chinese character would come out blank.
      TerminalFonts.prepare()
      let face = DownloadedWideFont.face
      #expect([DownloadedWideFont.postScriptName, DownloadedWideFont.builtIn].contains(face))
      #expect(TerminalFonts.resolvedWide(TerminalFonts.defaultWide) == face)
      #expect(TerminalFonts.resolvedWide("PingFang SC") == face, "the old stored default")
      #expect(TerminalFonts.faces().contains { $0.id == face || $0.family == face }, "the face drawn is one the renderer has")
    #else
      // PingFang is downloaded on demand; a Mac without it draws with the
      // built-in Heiti SC rather than failing to measure a cell.
      let face = TerminalFonts.resolvedWide(TerminalFonts.defaultWide)
      #expect(["PingFang SC", TerminalFonts.builtInWide].contains(face))
      #expect(TerminalFonts.resolvedWide("PingFang SC") == face, "the old stored default")
      #expect(TerminalFonts.faces().contains { $0.family == face }, "the face drawn is one the renderer has")
      #expect(TerminalFonts.faces().contains { $0.family == TerminalFonts.builtInWide })
      let fallback = FontMetrics(size: 13, scale: 2, wide: TerminalFonts.builtInWide)
      #expect(fallback.columns(fitting: 100000) == 1000, "the built-in face measures a cell")
      #expect(fallback.rows(fitting: 100000) == 500)
    #endif
    #expect(TerminalFonts.resolvedWide("HiraginoSans-W6") == "HiraginoSans-W6", "a chosen face is kept")
  }
}
