import Testing

@testable import TetherApp

@Suite("a remote shell's tty")
struct ShellTTYTests {
  @Test("the sibling pty on this connection is the shell")
  func oneShell() {
    let text = """
      last login: somewhere
      TETHER-TTY 3002
          1     0 ?
       2000  1000 ?
       2001  2000 ?
       2002  2001 pts/5
       3001  2000 ?
       3002  3001 ??
       3003  3002 ?
      TETHER-TTY-END
      """
    #expect(ShellTTY.candidates(in: text) == ["/dev/pts/5"])
  }

  @Test("every other session on the connection is a candidate, and this command's own pty is not")
  func severalShells() {
    let text = """
      TETHER-TTY 3002
       2000     1 ?
       2002  2001 pts/5
       2001  2000 ?
       3002  3001 ?
       3001  2000 ?
       3004  3002 pts/9
       4001  2000 ?
       4002  4001 ttys003
      TETHER-TTY-END
      """
    #expect(ShellTTY.candidates(in: text) == ["/dev/pts/5", "/dev/ttys003"])
  }

  @Test("a table without the marker names nothing")
  func unmarked() {
    #expect(ShellTTY.candidates(in: "2002 2001 pts/5\n").isEmpty)
    #expect(ShellTTY.candidates(in: "TETHER-TTY 1\n").isEmpty)
  }

  @Test("one pty of this size is this shell; two of this size is not a guess")
  func size() {
    let both = ["/dev/pts/5", "/dev/pts/8"]
    let sizes = [
      "/dev/pts/5": (columns: UInt16(120), rows: UInt16(40)),
      "/dev/pts/8": (columns: UInt16(80), rows: UInt16(24)),
    ]
    #expect(ShellTTY.choose(candidates: both, sizes: sizes, columns: 120, rows: 40) == "/dev/pts/5")
    let tied = [
      "/dev/pts/5": (columns: UInt16(120), rows: UInt16(40)),
      "/dev/pts/8": (columns: UInt16(120), rows: UInt16(40)),
    ]
    #expect(ShellTTY.choose(candidates: both, sizes: tied, columns: 120, rows: 40) == nil)
    #expect(ShellTTY.choose(candidates: both, sizes: [:], columns: 120, rows: 40) == nil)
  }

  @Test("stty is only asked about pty names the parser emits")
  func sizeCommand() {
    let command = ShellTTY.sizeCommand(for: ["/dev/pts/5", "/dev/ttys003"])
    #expect(command?.contains("'/dev/pts/5'") == true)
    #expect(command?.contains("'/dev/ttys003'") == true)
    #expect(ShellTTY.sizeCommand(for: ["/dev/pts/5", "/tmp/x"]) == nil)
    #expect(ShellTTY.sizeCommand(for: []) == nil)
  }

  @Test("stty's rows-then-columns become the view's columns and rows")
  func parseSizes() {
    let sizes = ShellTTY.parseSizes("noise\n/dev/pts/5 40 120\n/not/a/tty 1 1\n")
    #expect(sizes["/dev/pts/5"]?.columns == 120)
    #expect(sizes["/dev/pts/5"]?.rows == 40)
    #expect(sizes["/not/a/tty"] == nil)
  }
}
