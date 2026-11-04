import Foundation
import Testing
import TetherPluginKit

@testable import TetherApp

import struct TetherApp.Host

@Suite("Terminal labels")
struct TerminalLabelTests {
  private func row(
    _ name: String = "Terminal 1", pinned: String? = nil, session: String? = nil,
    command: String? = nil, directory: String? = nil
  ) -> TerminalLabel {
    TerminalLabel(id: UUID(), pinned: pinned, session: session, command: command, directory: directory, serial: name)
  }

  private func title(_ row: TerminalLabel, _ rest: TerminalLabel...) -> String? {
    TerminalLabels.titles([row] + rest)[row.id]
  }

  @Test("a name saved before pins is kept only when it was typed")
  func restored() {
    #expect(TerminalLabels.restoredPin(name: "Terminal 3", pinned: nil) == nil)
    #expect(TerminalLabels.restoredPin(name: "api", pinned: nil) == "api")
    #expect(TerminalLabels.restoredPin(name: "api", pinned: "logs") == "logs")
  }
}

@Suite("Foreground command")
struct LocalForegroundTests {

  #if os(macOS)
  #endif
}

@MainActor
@Suite("Terminal chip names")
struct TerminalChipTests {
  private func tab(_ name: String, host: Host = .local) -> SessionTab {
    SessionTab(preview: host, known: KnownHosts(), name: name, live: true)
  }

  @Test("ssh tabs on one machine are numbered, and a pin clears")
  func sshAndPin() {
    let tabs = TabSet()
    let first = tab("Terminal 1")
    let second = tab("Terminal 2")
    first.foregroundCommand = "ssh"
    second.foregroundCommand = "ssh"
    tabs.adopt(first)
    tabs.adopt(second)
    #expect(tabs.displayTitle(for: first.id) == "ssh 1")
    #expect(tabs.displayTitle(for: second.id) == "ssh 2")
    #expect(tabs.renameSeed(for: second.id) == "ssh")

    tabs.rename(first.id, to: "bastion")
    #expect(first.name == "Terminal 1")
    #expect(tabs.displayTitle(for: first.id) == "bastion")
    #expect(tabs.displayTitle(for: second.id) == "ssh")

    tabs.rename(first.id, to: " ")
    #expect(first.pinnedName == nil)
    #expect(tabs.displayTitle(for: first.id) == "ssh 1")
    #expect(tabs.displayTitle(for: second.id) == "ssh 2")
  }

  @Test("a tmux session is the chip, ahead of ssh")
  func tmuxSession() {
    let tabs = TabSet()
    let terminal = tab("Terminal 1")
    let attachment = StubAttachment()
    attachment.tabTitle = "dev"
    terminal.attach(attachment, for: "test.tmux")
    terminal.foregroundCommand = "ssh"
    terminal.labelPath = "/Users/ada/work/Nerve"
    tabs.adopt(terminal)
    #expect(tabs.displayTitle(for: terminal.id) == "dev")
  }

}
