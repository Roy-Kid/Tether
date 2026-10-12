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
    #expect(report.problem.refusedLogin, "Retry asks rather than sending what was refused")

    tab.acknowledge()
    #expect(tabs.problem == nil)
  }

  @Test("a host that could not be reached is not a refused login")
  func unreachableIsNotRefused() {
    let tabs = TabSet()
    let tab = tab(in: tabs)
    tab.fail(TetherError.unreachable(endpoint: "login.example.org:22", cause: "Connection refused"))
    #expect(tabs.problem?.problem.refusedLogin == false)
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

    tab.setProblemAside()
    #expect(tabs.problem == nil, "not now leaves the tab as it is")
    #expect(tabs.tabs.count == 1)
    #expect(tabs.reconnectReport(for: tab.id)?.problem.kind == .lost, "and it can still be reconnected")
  }

  @Test("a failure in a terminal not being looked at waits for it")
  func backgroundFailureWaits() throws {
    let tabs = TabSet()
    let behind = tab(in: tabs)
    let front = tab(in: tabs)
    #expect(tabs.current?.id == front.id)
    behind.fail(TetherError.unreachable(endpoint: "login.example.org:22", cause: "Connection refused"))
    #expect(tabs.problem == nil)
    tabs.select(behind.id)
    #expect(tabs.problem?.tab == behind.id, "told once it is the one on screen")
  }

  @Test("a reconnect that fails keeps what was on screen")
  func failedReconnectKeepsScreen() {
    let kept = TabProblem(
      tab: UUID(), host: host, problem: SessionProblem(kind: .couldNotConnect, reason: "refused"), keepsScreen: true)
    #expect(ConnectionDialog.problem(kept, close: {}, again: {}).actions.first?.title == "Not Now")
    let empty = TabProblem(tab: UUID(), host: host, problem: SessionProblem(kind: .couldNotConnect, reason: "refused"))
    #expect(ConnectionDialog.problem(empty, close: {}, again: {}).actions.first?.title == "Close",
      "a tab that never showed anything has nothing to keep")
  }

  @Test("a lost connection offers to reconnect; this machine restarts")
  func lostWording() {
    let lost = TabProblem(tab: UUID(), host: host, problem: SessionProblem(kind: .lost, reason: "reset by peer"))
    #expect(ConnectionDialog.problem(lost, close: {}, again: {}).title == "Connection to Arrhenius Lost")
    #expect(ConnectionDialog.problem(lost, close: {}, again: {}).actions.last?.title == "Reconnect")

    let local = TabProblem(tab: UUID(), host: .local, problem: SessionProblem(kind: .lost, reason: "gone"))
    #expect(ConnectionDialog.problem(local, close: {}, again: {}).actions.last?.title == "Restart")
  }

  @Test("the password question is a dialog that says where it is going")
  func passwordQuestion() {
    let dialog = ConnectionDialog.password(ConnectRequest(host: host), connect: { _ in }, cancel: {})
    #expect(dialog.title == "Arrhenius")
    #expect(dialog.message == "ada@login.example.org")
    #expect(dialog.fields == [Dialog.Field("Password", kind: .password)])
    #expect(dialog.actions.map(\.title) == ["Cancel", "Connect"])
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

  @Test("a refused saved password is offered to be replaced")
  func replaceOffer() {
    let tabs = TabSet()
    let tab = tab(in: tabs)
    tab.offer("new one")
    let offer = try! #require(tabs.passwordOffer)
    let dialog = ConnectionDialog.keep(offer, replacing: true, keep: {}, decline: {})
    #expect(dialog.title == "Update the saved password for Arrhenius?")
    #expect(dialog.actions.map(\.title) == ["Not Now", "Update"])
  }
}
