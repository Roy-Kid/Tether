import Testing

@testable import TetherApp

@Suite("a path typed at the prompt")
struct ShellQuoteTests {

  @Test("anything a shell would read is quoted, including a quote")
  func quoted() {
    #expect(shellQuoted("/tmp/a b.png") == "'/tmp/a b.png'")
    #expect(shellQuoted("/tmp/it's") == "'/tmp/it'\\''s'")
    #expect(shellQuoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
    #expect(shellQuoted("~/x") == "'~/x'", "a dropped path is literal, never expanded")
    #expect(shellQuoted("") == "''")
  }
}
