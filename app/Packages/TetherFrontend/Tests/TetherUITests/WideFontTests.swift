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
      #expect(TerminalFonts.resolvedWide(TerminalFonts.defaultWide) == "PingFang SC")
      #expect(TerminalFonts.resolvedWide("PingFang SC") == "PingFang SC")
    #endif
    #expect(TerminalFonts.resolvedWide("HiraginoSans-W6") == "HiraginoSans-W6", "a chosen face is kept")
  }
}
