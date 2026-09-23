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

  @Test("a name nobody in the directory has, the way Finder picks one")
  func freeName() {
    #expect(Names.free("plot.png", taken: []) == "plot.png")
    #expect(Names.free("plot.png", taken: ["plot.png"]) == "plot 2.png")
    #expect(Names.free("plot.png", taken: ["plot.png", "plot 2.png"]) == "plot 3.png")
    #expect(Names.free("Makefile", taken: ["Makefile"]) == "Makefile 2")
    #expect(Names.free(".env", taken: [".env"]) == ".env 2")
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

  @Test("a symbol says what kind of thing it is")
  func symbols() {
    #expect(Names.symbol(for: "src", kind: .directory) == "folder")
    #expect(Names.symbol(for: "plot.png", kind: .file) == "photo")
    #expect(Names.symbol(for: "paper.pdf", kind: .file) == "doc.richtext")
    #expect(Names.symbol(for: "main.rs", kind: .file) == "doc.text")
    #expect(Names.symbol(for: "latest", kind: .link) == "arrow.up.right.square")
    #expect(Names.symbol(for: "blob", kind: .file) == "doc")
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
  @Test("joining never doubles a separator")
  func join() {
    #expect(Paths.join("/", "a") == "/a")
    #expect(Paths.join("/a", "b") == "/a/b")
    #expect(Paths.join("/a/", "b") == "/a/b")
  }

  @Test("a parent is everything before the last component, and / is its own")
  func parent() {
    #expect(Paths.parent("/a/b/c") == "/a/b")
    #expect(Paths.parent("/a") == "/")
    #expect(Paths.parent("/") == "/")
  }

  @Test("ancestors run from the root down, for the path menu")
  func ancestors() {
    #expect(Paths.ancestors("/home/ada/runs") == ["/", "/home", "/home/ada", "/home/ada/runs"])
    #expect(Paths.ancestors("/") == ["/"])
  }

  @Test("the name of a directory, for a title")
  func name() {
    #expect(Paths.name("/home/ada/runs") == "runs")
    #expect(Paths.name("/") == "/")
  }
}
