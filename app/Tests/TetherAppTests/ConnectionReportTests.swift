import Foundation
import Tether
import TetherUI
import Testing

@testable import TetherApp

import struct TetherApp.Host

/// What a person is told when a connection does not work, and what they are
/// asked about a password that did. Nothing here is a page left in a tab:
/// each is one dialog that names the host.
@MainActor
@Suite("Connection reports")
struct ConnectionReportTests {
  private let host = Host(label: "Arrhenius", hostname: "login.example.org", port: 22, username: "ada")

  @Test("a cancelled reader cannot end the replacement shell",
    .enabled(if: TerminalSession.isLocalAvailable))
  func redialKeepsReplacementLive() async throws {
    let tabs = TabSet()
    let tab = SessionTab(host: .local, password: "", known: tabs.known, name: "Terminal 1")
    tabs.adopt(tab)
    defer { tabs.closeAll() }
    var lease = try await tab.connectionReady()
    for _ in 0..<3 {
      // Let the reader wait on the old shell before redial closes it.
      try await Task.sleep(for: .milliseconds(50))
      tab.redial(host: .local, password: "", typedNow: false)
      lease = try await tab.connectionReady()
      try await Task.sleep(for: .milliseconds(100))
      #expect(tab.isLive)
      #expect(tab.connection != nil)
      #expect(!tabs.isDisconnected(try #require(tabs.currentWorkspace)))
      #expect(tab.problem == nil)
      let output = try await lease.execute("printf reconnected")
      #expect(String(data: output.stdout, encoding: .utf8) == "reconnected")
    }
  }

  private func tab(in tabs: TabSet) -> SessionTab {
    let tab = SessionTab(
      preview: host, known: KnownHosts(location: URL(fileURLWithPath: "/dev/null")), name: "Terminal 1",
      live: false)
    tabs.adopt(tab)
    return tab
  }

  @Test("a failure becomes one dialog that names the host and the reason")
  func failureIsReported() {
    let tabs = TabSet()
    let tab = tab(in: tabs)
    tab.fail(TetherError.authenticationFailed(remaining: ["publickey", "keyboard-interactive"]))

    let report = try! #require(tabs.problem)
    let dialog = ConnectionDialog.problem(report, close: {}, again: {})
    #expect(dialog.title == "Could Not Connect to Arrhenius")
    #expect(dialog.message == "Authentication failed. The server accepts: publickey, keyboard-interactive.")
    #expect(dialog.actions.map(\.title) == ["Close", "Retry"])
    #expect(report.coversTerminal, "the failure covers that terminal")
    #expect(report.problem.refusedLogin, "Retry asks rather than sending what was refused")

    tab.acknowledge()
    #expect(tabs.problem == nil)
  }

  @Test("a person's own no closes the tab without a report")
  func declineCloses() {
    let tabs = TabSet()
    let tab = tab(in: tabs)
    tab.fail(CancellationError())
    #expect(tabs.tabs.isEmpty)
    #expect(tabs.problem == nil)
  }

  @Test("a lost connection is a state: kept in the tab, asked about only when acted on")
  func lostIsQuiet() throws {
    let tabs = TabSet()
    let tab = tab(in: tabs)
    tab.finish(.lost(cause: "reset by peer"))
    if case .lost = tab.stage {} else { Issue.record("a dropped connection is lost, not ended") }
    #expect(tab.stateName == "Disconnected")
    #expect(tab.isDisconnected && tab.canReconnect)
    #expect(tabs.problem == nil, "no dialog of its own accord")
    #expect(tabs.isDisconnected(try #require(tabs.currentWorkspace)), "marked on its tab instead")
    #expect(tabs.canPerform(.reconnect))

    tab.raiseProblem()
    let report = try #require(tabs.problem)
    let dialog = ConnectionDialog.problem(report, close: { Issue.record("Escape must not close") }, again: {})
    #expect(dialog.actions.map(\.title) == ["Not Now", "Reconnect"])
    #expect(dialog.cancelAction == 0)
    #expect(report.coversTerminal)

    tab.setProblemAside()
    #expect(tabs.problem == nil, "not now leaves the tab as it is")
    #expect(tabs.tabs.count == 1)
    #expect(tabs.reconnectReport(for: tab.id)?.problem.kind == .lost, "and it can still be reconnected")
  }

  @Test("a password that worked is offered once, and a no holds for the host")
  func keepOffer() {
    let tabs = TabSet()
    let first = tab(in: tabs)
    first.offer("hunter2")
    let offer = try! #require(tabs.passwordOffer)
    #expect(
      ConnectionDialog.keep(offer, replacing: false, keep: {}, decline: {}).title == "Save the password for Arrhenius?")

    tabs.answer(offer, kept: false)
    #expect(tabs.passwordOffer == nil)
    let second = tab(in: tabs)
    second.offer("hunter2")
    #expect(tabs.passwordOffer == nil, "asked once, not on every login")
  }

}

extension ConnectionReportTests {
  @Test("plugin terminal identity is the local shell's TTY and vanishes on close",
    .enabled(if: TerminalSession.isLocalAvailable))
  func pluginIdentityFollowsTerminalLifetime() async throws {
    let tabs = TabSet()
    let shell = SessionTab(host: .local, password: "", known: tabs.known, name: "Terminal 1")
    tabs.adopt(shell)
    defer { tabs.closeAll() }
    _ = try await shell.connectionReady()
    let identity = try #require(shell.pluginTerminalIdentity)
    #expect(identity.host == LocalMachine.name)
    #expect(identity.terminal == shell.terminalName)
    shell.name = "renamed"
    #expect(shell.pluginTerminalIdentity == identity, "display names cannot change task association")
    shell.close()
    #expect(shell.pluginTerminalIdentity == nil)
  }
}
