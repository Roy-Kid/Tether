import Foundation
import Testing
import Tether
import TetherPluginKit
@testable import TetherApp
import struct TetherApp.Host

@MainActor
private final class InteractionFixture {
  let location = temporaryFile("hosts.json")
  let suite = "Tether.InteractionTests.\(UUID())"
  let defaults: UserDefaults
  let secrets = MemorySecrets()
  let tabs: TabSet
  let interaction: WorkspaceInteraction
  let quickID = UUID()

  init() {
    defaults = UserDefaults(suiteName: suite)!
    tabs = TabSet(defaults: defaults, inspectActivity: { _ in .idle })
    let store = HostStore(location: location, secrets: secrets)
    interaction = WorkspaceInteraction(tabs: tabs, store: store, registry: PluginRegistry(), secrets: secrets)
    interaction.register(id: interaction.workspaceHostID, kind: .workspace)
    interaction.register(id: quickID, kind: .quick)
  }

  func cleanUp() {
    interaction.stop()
    tabs.closeAll()
    defaults.removePersistentDomain(forName: suite)
    removeDirectory(of: location)
  }

  func show(_ id: UUID, key: Bool = false, renderVisible: Bool = true) {
    interaction.update(id: id, state: WorkspaceHostState(
      orderedIn: true, renderVisible: renderVisible, keyWithinHost: key))
  }

  func addTerminal(host: Host = .local, live: Bool = false) -> SessionTab {
    let tab = SessionTab(preview: host, known: tabs.known, name: "Terminal", live: live)
    tabs.adopt(tab)
    return tab
  }

  /// No network or SSH master lookup: this policy must collect a password
  /// before a connection could be attempted. Preview sessions never dial.
  func remoteHost() -> Host {
    let identity = AccountIdentity(name: "Test")
    var profile = HostProfile(id: UUID(), label: "Test Host", hostname: "invalid.example", port: 22, username: "test",
      authentication: AuthenticationProfile(identity: identity,
        primary: CredentialDescriptor(identityID: identity.id, purpose: .ssh)))
    profile.authentication.confirmation = .confirmConnection
    return Host(id: profile.id, label: profile.label, hostname: profile.hostname, port: profile.port,
      username: profile.username, profile: profile)
  }
}

@MainActor
@Suite("Workspace interaction")
struct WorkspaceInteractionTests {
  @Test("stop before owned remote work starts prevents every operation from resurrecting requests or sessions",
    arguments: ["open", "split", "retry", "restore"])
  func stopBeforeOwnedWorkStarts(operation: String) async throws {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let host = f.remoteHost()
    let tab = f.addTerminal(host: host, live: operation == "split")
    f.show(f.quickID, key: true)
    f.interaction.start()
    switch operation {
    case "open": f.interaction.open(host)
    case "split": f.interaction.splitTerminal(tab.id, direction: .right)
    case "retry": f.interaction.retry(try #require(f.tabs.reconnectReport(for: tab.id)))
    default:
      f.tabs.close(tab.id)
      f.tabs.requestRestoreTab()
    }
    #expect(f.interaction.ownedWorkCount == 1)
    f.interaction.stop()
    f.interaction.stop()
    f.tabs.closeAll()
    for _ in 0..<100 where f.interaction.ownedWorkCount != 0 { await Task.yield() }
    #expect(f.interaction.ownedWorkCount == 0)
    #expect(f.interaction.connectRequests.isEmpty)
    #expect(f.interaction.reconnectAnswers.isEmpty)
    #expect(f.interaction.notice == nil)
    #expect(f.tabs.tabs.isEmpty)
  }

  @Test("stop while split awaits a lease cancels its waiter and cannot publish a late failure")
  func stopDuringConnectionWait() async {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let source = f.addTerminal(host: f.remoteHost(), live: true)
    f.show(f.quickID, key: true)
    f.interaction.start()
    f.interaction.splitTerminal(source.id, direction: .right)
    for _ in 0..<100 where source.connectionWaiterCount == 0 { await Task.yield() }
    #expect(source.connectionWaiterCount == 1)
    f.interaction.stop()
    f.interaction.stop()
    for _ in 0..<100 where f.interaction.ownedWorkCount != 0 { await Task.yield() }
    #expect(source.connectionWaiterCount == 0)
    #expect(f.interaction.ownedWorkCount == 0)
    #expect(f.interaction.connectRequests.isEmpty)
    #expect(f.interaction.notice == nil)
    #expect(f.tabs.tabs.count == 1)
    #expect(!f.interaction.dispatch(.newTab, from: f.quickID))
  }

  @Test("being visible alone never claims the effective host")
  func orderedHostsNeedAClaim() {
    let f = InteractionFixture(); defer { f.cleanUp() }
    f.show(f.interaction.workspaceHostID)
    f.show(f.quickID)
    #expect(f.interaction.effectiveHost == nil)
    #expect(!f.interaction.drivesSurface(f.quickID))
    #expect(f.interaction.claim(f.quickID))
    #expect(f.interaction.effectiveHost == f.quickID)
    #expect(!f.interaction.drivesSurface(f.interaction.workspaceHostID))
  }

  @Test("occlusion and focus leaving the app retain context and the effective grid")
  func occlusionIsNotHide() {
    let f = InteractionFixture(); defer { f.cleanUp() }
    f.show(f.quickID, key: true)
    f.show(f.quickID, renderVisible: false)
    #expect(f.interaction.effectiveHost == f.quickID)
    #expect(f.interaction.lastEffectiveHost == f.quickID)
    #expect(f.interaction.drivesSurface(f.quickID), "render visibility gates frame publication, not grid ownership")
    #expect(f.tabs.menuShortcuts == nil)
    #expect(!f.interaction.dispatch(.zen), "a nil source cannot revive the last terminal without native key ownership")
  }

  @Test("hiding falls back only to a previously claimed eligible host and never reveals a hidden main")
  func hideEligibility() {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let main = f.interaction.workspaceHostID
    f.show(main, key: true)
    f.show(main)
    f.show(f.quickID, key: true)
    f.interaction.update(id: f.quickID, state: WorkspaceHostState())
    #expect(f.interaction.effectiveHost == main)
    f.interaction.update(id: main, state: WorkspaceHostState())
    f.show(f.quickID, key: true)
    f.interaction.update(id: f.quickID, state: WorkspaceHostState())
    #expect(f.interaction.effectiveHost == nil)
    #expect(f.interaction.lastEffectiveHost == f.quickID)
  }

  @Test("miniaturizing withdraws eligibility while occlusion alone does not")
  func miniaturizedHostCannotClaim() {
    let f = InteractionFixture(); defer { f.cleanUp() }
    f.show(f.quickID, key: true)
    f.interaction.update(id: f.quickID, state: WorkspaceHostState(orderedIn: true, miniaturized: true))
    #expect(f.interaction.effectiveHost == nil)
    #expect(!f.interaction.claim(f.quickID))
    #expect(!f.interaction.dispatch(.newTab, from: f.quickID))
  }

  @Test("a presentation fixes its owner until true dismissal, then applies the deferred explicit claim")
  func blockingLeaseOwnsHost() throws {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let main = f.interaction.workspaceHostID
    f.show(main)
    f.show(f.quickID, key: true)
    let lease = try #require(f.interaction.acquirePresentation())
    f.interaction.presentationDidPresent(lease)
    #expect(!f.interaction.claim(main))
    #expect(!f.interaction.dispatch(.zen, from: main))
    #expect(!f.interaction.dispatch(.zen, from: f.quickID))
    #expect(!f.tabs.zen)
    #expect(f.interaction.presentationOwner == f.quickID)
    #expect(f.interaction.effectiveHost == f.quickID)
    #expect(!f.interaction.inputAllowed(in: f.quickID))
    f.interaction.presentationDidDismiss(lease)
    #expect(f.interaction.presentationOwner == nil)
    #expect(f.interaction.effectiveHost == main)
    f.interaction.presentationDidDismiss(lease)
    #expect(f.interaction.effectiveHost == main, "duplicate native completion is harmless")
  }

  @Test("queued questions share the owner and every lease must truly dismiss")
  func multipleLeases() throws {
    let f = InteractionFixture(); defer { f.cleanUp() }
    f.show(f.quickID, key: true)
    f.show(f.interaction.workspaceHostID)
    let first = try #require(f.interaction.acquirePresentation())
    let second = try #require(f.interaction.acquirePresentation(in: f.interaction.workspaceHostID))
    #expect(second.hostID == f.quickID)
    f.interaction.presentationDidDismiss(first)
    #expect(f.interaction.hasBlockingPresentation)
    #expect(!f.interaction.claim(f.interaction.workspaceHostID))
    f.interaction.presentationDidDismiss(second)
    #expect(!f.interaction.hasBlockingPresentation)
    #expect(f.interaction.effectiveHost == f.interaction.workspaceHostID)
  }

  @Test("unregistering a presented owner does not crash or grant another host its pending questions")
  func unregisterWhilePresenting() async throws {
    let f = InteractionFixture(); defer { f.cleanUp() }
    f.show(f.quickID, key: true)
    let lease = try #require(f.interaction.acquirePresentation())
    f.interaction.presentationDidPresent(lease)
    f.interaction.unregister(id: f.quickID)
    #expect(f.interaction.presentationOwner == f.quickID)
    #expect(!f.interaction.drivesSurface(f.quickID))
    #expect(f.interaction.acquirePresentation() == nil, "there is no longer an anchor to enqueue against")
    f.interaction.presentationDidDismiss(lease)
    #expect(f.interaction.effectiveHost == nil)
  }

  @Test("ordinary actions execute in the claimed host, including consecutive identical toggles")
  func repeatedActionsExactlyOnce() {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let main = f.interaction.workspaceHostID
    f.show(main)
    f.show(f.quickID)
    for _ in 0..<2 {
      #expect(f.interaction.dispatch(.zen, from: f.quickID))
    }
    #expect(!f.tabs.zen, "each event toggles once, neither duplicated nor coalesced")
    #expect(f.interaction.effectiveHost == f.quickID)
    #expect(f.interaction.dispatch(.toggleTabBar, from: f.quickID))
    #expect(!f.tabs.showsTabBar(for: f.quickID))
    #expect(f.tabs.showsTabBar(for: main), "window-local visibility is preserved")
    #expect(f.interaction.dispatch(.commandMenu, from: f.quickID))
    #expect(f.tabs.palette == .command)
    #expect(f.interaction.dispatch(.quickSwitch, from: f.quickID))
    #expect(f.tabs.palette == .quickSwitch)
    #expect(f.interaction.dispatch(.closeTerminal, from: f.quickID))
    #expect(f.tabs.palette == nil)
    #expect(f.interaction.dispatch(.changeHost, from: f.quickID))
    #expect(f.tabs.hostPicker)
    #expect(f.interaction.dispatch(.closeTerminal, from: f.quickID))
    #expect(!f.tabs.hostPicker)
  }

  @Test("repeated New commands deliver every request without a view observer or intent slot overwrite",
    arguments: [WorkspaceAction.newTab, .newTerminal])
  func repeatedNewCommands(_ action: WorkspaceAction) async {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let host = f.remoteHost()
    _ = f.addTerminal(host: host)
    f.show(f.quickID)
    for _ in 0..<3 { #expect(f.interaction.dispatch(action, from: f.quickID)) }
    for _ in 0..<100 where f.interaction.connectRequests.count < 3 { await Task.yield() }
    #expect(f.interaction.connectRequests.count == 3)
    #expect(Set(f.interaction.connectRequests.map(\.id)).count == 3)
    #expect(f.tabs.tabs.count == 1, "no session is dialled before a password is supplied")
    #expect(f.tabs.intent == nil)
    #expect(f.interaction.effectiveHost == f.quickID)
  }

  @Test("all intent producers deliver repeated values synchronously to the sole controller")
  func repeatedIntentAssignments() async {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let host = f.remoteHost()
    f.show(f.quickID, key: true)
    f.tabs.intent = .connect(host)
    f.tabs.intent = .connect(host)
    for _ in 0..<100 where f.interaction.connectRequests.count < 2 { await Task.yield() }
    #expect(f.interaction.connectRequests.count == 2)
    #expect(f.tabs.intent == nil)
  }

  @Test("cancelling a plugin reconnect settles its queued password continuation exactly once")
  func cancelledReconnectQuestionSettlesOnce() async {
    let f = InteractionFixture(); defer { f.cleanUp() }
    f.show(f.quickID, key: true)
    let host = f.remoteHost()
    let task = Task {
      do { _ = try await f.interaction.reconnect(host: host); return false }
      catch { return error is CancellationError }
    }
    for _ in 0..<100 where f.interaction.connectRequests.isEmpty { await Task.yield() }
    #expect(f.interaction.connectRequests.count == 1)
    #expect(f.interaction.reconnectAnswers.count == 1)
    task.cancel()
    #expect(await task.value)
    #expect(f.interaction.connectRequests.isEmpty)
    #expect(f.interaction.reconnectAnswers.isEmpty)
    #expect(f.tabs.tabs.isEmpty)
    f.interaction.stop()
    f.interaction.stop()
  }

  @Test("stopping the controller resumes each pending reconnect once without opening a session")
  func stopSettlesReconnectQuestion() async {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let host = f.remoteHost()
    let task = Task {
      do { _ = try await f.interaction.reconnect(host: host); return false }
      catch { return error is CancellationError }
    }
    for _ in 0..<100 where f.interaction.connectRequests.isEmpty { await Task.yield() }
    #expect(f.interaction.connectRequests.count == 1)
    f.interaction.stop()
    f.interaction.stop()
    #expect(await task.value)
    #expect(f.interaction.reconnectAnswers.isEmpty)
    #expect(f.interaction.connectRequests.isEmpty)
    #expect(f.tabs.tabs.isEmpty)
  }

  @Test("reconnect and restore collect one password for the existing terminal or history record")
  func reconnectAndRestoreRequests() async throws {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let tab = f.addTerminal(host: f.remoteHost())
    f.show(f.quickID)
    #expect(f.interaction.dispatch(.reconnect, from: f.quickID))
    #expect(f.interaction.dispatch(.reconnect, from: f.quickID))
    for _ in 0..<100 where f.interaction.connectRequests.isEmpty { await Task.yield() }
    #expect(f.interaction.connectRequests.count == 1, "one retrying terminal cannot own two password questions")
    let retry = try #require(f.interaction.connectRequests.first)
    #expect(retry.retrying == tab.id)
    f.interaction.cancelConnect(retry)
    #expect(f.tabs.tabs.isEmpty)
    #expect(f.interaction.dispatch(.restoreTab, from: f.quickID))
    #expect(!f.interaction.dispatch(.restoreTab, from: f.quickID), "restoration already in flight is not duplicated")
    for _ in 0..<100 where f.interaction.connectRequests.isEmpty { await Task.yield() }
    #expect(f.interaction.connectRequests.count == 1)
    #expect(f.interaction.connectRequests.first?.restoring == f.tabs.restoringTab)
  }

  @Test("rename and close target the shared session while a second workspace remains isolated")
  func isolationAndClose() {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let other = InteractionFixture(); defer { other.cleanUp() }
    let tab = f.addTerminal()
    let untouched = other.addTerminal()
    f.show(f.quickID)
    other.show(other.interaction.workspaceHostID, key: true)
    #expect(!other.interaction.dispatch(.zen, from: f.quickID))
    #expect(f.interaction.dispatch(.renameTerminal, from: f.quickID))
    #expect(f.tabs.renaming == tab.id)
    #expect(!f.interaction.dispatch(.zen, from: f.quickID), "a rename field holds its own input")
    f.tabs.rename(tab.id, to: "Renamed")
    #expect(f.interaction.dispatch(.renameTab, from: f.quickID))
    f.tabs.rename(f.tabs.currentWorkspace!.id, to: "Workspace")
    #expect(f.interaction.dispatch(.closeTerminal, from: f.quickID))
    #expect(f.tabs.tabs.isEmpty)
    #expect(other.tabs.tabs.first === untouched)
    #expect(!other.tabs.zen)
    #expect(f.tabs.interaction === f.interaction)
    #expect(tab.interaction === f.interaction)
  }

  @Test("re-registering the same logical host preserves its anchor and never changes its role")
  func stableLogicalRegistration() {
    let f = InteractionFixture(); defer { f.cleanUp() }
    let anchor = f.interaction.windowAnchor(for: f.quickID)
    f.interaction.register(id: f.quickID, kind: .workspace)
    #expect(f.interaction.windowAnchor(for: f.quickID) === anchor)
    f.show(f.quickID)
    #expect(f.interaction.claim(f.quickID))
    #expect(!f.interaction.claim(UUID()))
    #expect(!f.interaction.dispatch(.splitRight, from: f.quickID), "a disabled action is not consumed")
  }
}
