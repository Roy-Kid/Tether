import Foundation
import Testing

#if os(macOS)
@testable import TetherApp

@Suite("opening a path")
struct OpenPathTests {
  private func standard(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  @Test("a path is this machine's file, and anything else is not")
  func resolves() {
    let home = NSHomeDirectory()
    #expect(OpenPath.fileURL(from: "/var/empty/a", workingDirectory: nil)?.path == standard("/var/empty/a"))
    #expect(OpenPath.fileURL(from: "~", workingDirectory: nil)?.path == standard(home))
    #expect(OpenPath.fileURL(from: "~/Docs", workingDirectory: nil)?.path == standard(home + "/Docs"))
    #expect(OpenPath.fileURL(from: "file:///var/empty/a", workingDirectory: nil)?.path == standard("/var/empty/a"))
    #expect(OpenPath.fileURL(from: "src/main.rs", workingDirectory: "/work")?.path == standard("/work/src/main.rs"))
    #expect(OpenPath.fileURL(from: "src/main.rs", workingDirectory: "relative") == nil)
    #expect(OpenPath.fileURL(from: "src/main.rs", workingDirectory: nil) == nil)
    #expect(OpenPath.fileURL(from: "a\nb", workingDirectory: "/work") == nil)
    #expect(OpenPath.fileURL(from: "   ", workingDirectory: "/work") == nil)
    #expect(OpenPath.fileURL(from: "file:", workingDirectory: nil) == nil)
  }

  @Test("the clipboard is offered only when it is a path")
  func suggestion() {
    #expect(OpenPath.suggestion(from: "  ~/Docs  ", workingDirectory: nil) == "~/Docs")
    #expect(OpenPath.suggestion(from: "/var/empty/a", workingDirectory: nil) == "/var/empty/a")
    #expect(OpenPath.suggestion(from: "hello", workingDirectory: "/work") == "")
    #expect(OpenPath.suggestion(from: "src/main.rs", workingDirectory: "/work") == "src/main.rs")
    #expect(OpenPath.suggestion(from: "src/main.rs", workingDirectory: nil) == "")
    #expect(OpenPath.suggestion(from: "/var/a\n/var/b", workingDirectory: nil) == "")
    #expect(OpenPath.suggestion(from: nil, workingDirectory: nil) == "")
  }
}
#endif
