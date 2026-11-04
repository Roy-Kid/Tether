import Foundation
import Testing

@testable import FilesPlugin

@Suite("names from the far side")
struct NamesTests {
  @Test("control characters and direction overrides never reach the screen")
  func displayIsClean() {
    #expect(Names.display("report.pdf") == "report.pdf")
    #expect(Names.display("a\u{1B}[31mred") == "a�[31mred")
    #expect(Names.display("line\nbreak") == "line�break")
    // "txt.exe" spelled backwards behind a right-to-left override.
    #expect(Names.display("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
    #expect(Names.display("a\u{2066}b\u{2069}c\u{200F}") == "abc")
  }

  @Test("a name becomes one local file name, never a path")
  func localNameIsOneComponent() {
    #expect(Names.local("plot.png") == "plot.png")
    #expect(Names.local("a/b") == "a_b")
    #expect(Names.local("..") == "file")
    #expect(Names.local(".") == "file")
    #expect(Names.local("") == "file")
    #expect(Names.local("x:y") == "x_y")
    #expect(Names.local("\u{0}") == "�")
  }

  @Test("what runs when opened is never opened")
  func riskyTypes() {
    #expect(Names.isRisky("setup.command"))
    #expect(Names.isRisky("run.sh"))
    #expect(Names.isRisky("Thing.app"))
    #expect(Names.isRisky("install.pkg"))
    #expect(!Names.isRisky("plot.png"))
    #expect(!Names.isRisky("paper.pdf"))
  }

  @Test("a path is quoted only when a shell would read something into it")
  func quoting() {
    #expect(Names.shellQuoted("/data/run-1/out.csv") == "/data/run-1/out.csv")
    #expect(Names.shellQuoted("/data/my run/out.csv") == "'/data/my run/out.csv'")
    #expect(Names.shellQuoted("/data/it's") == "'/data/it'\\''s'")
  }
}

@Suite("paths on the far side")
struct PathsTests {

}
