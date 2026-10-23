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

  @Test("a running program is the name, and one of them needs no number")
  func command() {
    #expect(title(row(command: "ssh", directory: "Nerve")) == "ssh")
  }

  @Test("several ssh sessions are numbered in order")
  func sshNumbers() {
    let first = row(command: "ssh")
    let second = row("Terminal 2", command: "ssh")
    let third = row("Terminal 3", command: "vim")
    let titles = TerminalLabels.titles([first, second, third])
    #expect(titles[first.id] == "ssh 1")
    #expect(titles[second.id] == "ssh 2")
    #expect(titles[third.id] == "vim")
  }

  @Test("tmux session names the tab ahead of the program")
  func session() {
    #expect(title(row(session: "dev", command: "tmux", directory: "Nerve")) == "dev")
  }

  @Test("a typed name stays, and is not numbered with the ssh tabs")
  func pin() {
    let pinned = row(pinned: "api", command: "ssh")
    let other = row("Terminal 2", command: "ssh")
    let titles = TerminalLabels.titles([pinned, other])
    #expect(titles[pinned.id] == "api")
    #expect(titles[other.id] == "ssh")
    #expect(TerminalLabels.seed(pinned) == "api")
    #expect(TerminalLabels.seed(other) == "ssh")
  }

  @Test("an idle shell uses the directory, and home is ~")
  func directory() {
    #expect(title(row(directory: "Nerve")) == "Nerve")
    #expect(TerminalLabels.directoryName("/Users/ada/work/Nerve/", home: "/Users/ada") == "Nerve")
    #expect(TerminalLabels.directoryName("/Users/ada", home: "/Users/ada/") == "~")
    #expect(TerminalLabels.directoryName("/", home: "/") == "~")
    #expect(TerminalLabels.directoryName("/", home: "/Users/ada") == nil)
    #expect(TerminalLabels.directoryName("relative", home: nil) == nil)
  }

  @Test("Terminal N remains when nothing else is known")
  func serial() {
    #expect(title(row()) == "Terminal 1")
    #expect(TerminalLabels.isSerial("Terminal 12"))
    #expect(!TerminalLabels.isSerial("Terminal"))
    #expect(!TerminalLabels.isSerial("api"))
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
  @Test("the prompt is not a command")
  func prompt() {
    #expect(LocalForeground.picked(shellPGID: 10, foreground: 10, leader: "zsh") == nil)
    #expect(LocalForeground.picked(shellPGID: 10, foreground: 0, leader: "ssh") == nil)
    #expect(LocalForeground.picked(shellPGID: 10, foreground: 40, leader: "-zsh") == nil)
  }

  @Test("the foreground program is its own name")
  func program() {
    #expect(LocalForeground.picked(shellPGID: 10, foreground: 40, leader: "/usr/bin/ssh") == "ssh")
    #expect(LocalForeground.picked(shellPGID: 10, foreground: 40, leader: "cargo") == "cargo")
  }

  #if os(macOS)
  @Test("this process can be read")
  func readable() {
    let name = LocalForeground.leaderName(pid: UInt32(getpid()))
    #expect(name?.isEmpty == false)
  }
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

  @Test("the same command on two machines is not one series")
  func perHost() {
    let tabs = TabSet()
    let lab = Host(label: "lab", hostname: "lab.example", port: 22, username: "ada", keyPath: nil)
    let here = tab("Terminal 1")
    let there = tab("Terminal 1", host: lab)
    here.foregroundCommand = "ssh"
    there.foregroundCommand = "ssh"
    tabs.adopt(here)
    tabs.adopt(there)
    #expect(tabs.displayTitle(for: here.id) == "ssh")
    #expect(tabs.displayTitle(for: there.id) == "ssh")
  }

  @Test("an idle shell is named for its directory")
  func directory() async {
    let tabs = TabSet(inspectActivity: { _ in .unknown })
    let terminal = tab("Terminal 4")
    terminal.labelPath = NSHomeDirectory()
    tabs.adopt(terminal)
    #expect(tabs.displayTitle(for: terminal.id) == "~")
    #expect(tabs.closeQuestion == "Close?")
    tabs.requestClose(terminal.id)
    while tabs.checkingClose != nil { await Task.yield() }
    #expect(tabs.closeQuestion == "Close ~?")
  }
}
