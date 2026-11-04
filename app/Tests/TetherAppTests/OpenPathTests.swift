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

}
#endif
