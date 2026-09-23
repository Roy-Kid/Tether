import Testing

@testable import TetherApp

@Suite("a path typed at the prompt")
struct ShellQuoteTests {
  @Test("an ordinary path is typed as it is")
  func plain() {
    #expect(shellQuoted("/Users/ada/plot-1.png") == "/Users/ada/plot-1.png")
  }

  @Test("anything a shell would read is quoted, including a quote")
  func quoted() {
    #expect(shellQuoted("/tmp/a b.png") == "'/tmp/a b.png'")
    #expect(shellQuoted("/tmp/it's") == "'/tmp/it'\\''s'")
    #expect(shellQuoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
    #expect(shellQuoted("~/x") == "'~/x'", "a dropped path is literal, never expanded")
    #expect(shellQuoted("") == "''")
  }
}
