#if os(macOS)
import Testing
import Tether
@testable import TetherApp
import struct TetherApp.Host

/// A Nerve row names a tty and a folder. The folder is how the click used to
/// open Finder. Landing uses the tty, and a file URL is not opened.
@MainActor
@Suite("Nerve row landing")
struct SessionFocusTests {
  @Test("a file URL is not a session")
  func aFileURLIsNotASession() {
    let landed = SessionFocus.land(
      host: nil, terminal: nil, directory: "/tmp/not-a-tether-tab",
      url: "file:///tmp/not-a-tether-tab", sets: [TabSet()])
    #expect(landed == "none")
    #expect(FocusLink.url("file:///tmp/not-a-tether-tab") == nil)
  }

  @Test("a named terminal is that tab", .enabled(if: TerminalSession.isLocalAvailable))
  func aNamedTerminalIsThatTab() async throws {
    let tabs = TabSet()
    let first = SessionTab(host: .local, password: "", known: tabs.known, name: "Build")
    let second = SessionTab(host: .local, password: "", known: tabs.known, name: "Other")
    tabs.adopt(first)
    tabs.adopt(second)
    defer { tabs.closeAll() }
    _ = try await first.connectionReady()
    _ = try await second.connectionReady()
    let identity = try #require(first.pluginTerminalIdentity)
    #expect(tabs.selected == second.id)

    let landed = SessionFocus.land(
      host: identity.host, terminal: identity.terminal,
      directory: "/tmp/not-a-tether-tab", url: "file:///tmp/not-a-tether-tab",
      sets: [tabs])
    #expect(landed == "tab")
    #expect(tabs.selected == first.id)

    tabs.select(second.id)
    let bare = identity.terminal.hasPrefix("/dev/")
      ? String(identity.terminal.dropFirst("/dev/".count)) : identity.terminal
    // The same tty on another machine is another terminal.
    let elsewhere = SessionFocus.land(
      host: "arrhenius", terminal: bare, directory: nil, url: nil, sets: [tabs])
    #expect(elsewhere == "none")
    #expect(tabs.selected == second.id)
    let again = SessionFocus.land(
      host: LocalMachine.name.uppercased(), terminal: bare,
      directory: nil, url: nil, sets: [tabs])
    #expect(again == "tab")
    #expect(tabs.selected == first.id)
  }
}
#endif
