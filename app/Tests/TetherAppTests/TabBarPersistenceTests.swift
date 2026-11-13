#if os(macOS)
import Foundation
import Testing
import TetherPluginKit
@testable import TetherApp

@MainActor
private final class TabBarWorkspace {
  let tabs: TabSet
  let interaction: WorkspaceInteraction
  var mainID: UUID { interaction.workspaceHostID }
  var quickID: UUID { tabs.quickTerminal.panelID }

  init(defaults: UserDefaults, store: HostStore, sharing quick: QuickTerminalController? = nil) {
    tabs = TabSet(defaults: defaults)
    if let quick { tabs.quickTerminal = quick }
    interaction = WorkspaceInteraction(tabs: tabs, store: store, registry: PluginRegistry(), secrets: MemorySecrets())
    if quick == nil { tabs.quickTerminal.interaction = interaction }
    interaction.register(id: mainID, kind: .workspace)
    if quick == nil { interaction.register(id: quickID, kind: .quick) }
  }

  func focus(_ id: UUID) {
    interaction.update(id: id, state: WorkspaceHostState(orderedIn: true, renderVisible: true))
    #expect(interaction.claim(id))
  }

  func close() { interaction.stop(); tabs.closeAll() }
}

@MainActor
@Suite("Tab bar persistence")
struct TabBarPersistenceTests {
  // A stable on-disk preference contract, deliberately not a generated host UUID.
  private let quickKey = "quickTerminal.tabBarVisible"

  private func isolated(_ body: (UserDefaults, HostStore) -> Void) {
    let suite = "Tether.TabBarPersistence.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let file = temporaryFile("hosts.json")
    defer { defaults.removePersistentDomain(forName: suite); removeDirectory(of: file) }
    defaults.set(false, forKey: "quickTerminal.enabled")
    defaults.set(false, forKey: "quickTerminal.menuBarIcon")
    body(defaults, HostStore(location: file, secrets: MemorySecrets()))
  }

  @Test("missing preferences use the existing default and quick keeps that initial choice across main changes")
  func defaultChoiceIsInheritedOnce() {
    isolated { defaults, store in
      let first = TabBarWorkspace(defaults: defaults, store: store)
      defer { first.close() }
      #expect(first.tabs.showsTabBar(for: first.mainID) == TabBarPreference.default)
      #expect(first.tabs.showsTabBar(for: first.quickID) == TabBarPreference.default)
      first.tabs.toggleTabBar(for: first.mainID)
      let next = TabBarWorkspace(defaults: defaults, store: store)
      defer { next.close() }
      #expect(next.tabs.showsTabBar(for: next.mainID) == !TabBarPreference.default)
      #expect(next.tabs.showsTabBar(for: next.quickID) == TabBarPreference.default)
    }
  }

  @Test("main show and hide choices survive fresh TabSet and interaction UUIDs without changing quick",
    arguments: [false, true])
  func mainChoiceSurvivesReconstruction(choice: Bool) {
    isolated { defaults, store in
      defaults.set(!choice, forKey: TabBarPreference.key)
      defaults.set(!choice, forKey: quickKey)
      let first = TabBarWorkspace(defaults: defaults, store: store)
      defer { first.close() }
      first.tabs.toggleTabBar(for: first.mainID)
      #expect(first.tabs.showsTabBar(for: first.mainID) == choice)
      #expect(first.tabs.showsTabBar(for: first.quickID) == !choice)
      #expect(defaults.bool(forKey: TabBarPreference.key) == choice)
      let next = TabBarWorkspace(defaults: defaults, store: store)
      defer { next.close() }
      #expect(first.mainID != next.mainID && first.quickID != next.quickID)
      #expect(next.tabs.showsTabBar(for: next.mainID) == choice)
      #expect(next.tabs.showsTabBar(for: next.quickID) == !choice)
    }
  }

  @Test("quick show and hide choices survive fresh UUIDs without changing the workspace preference",
    arguments: [false, true])
  func quickChoiceSurvivesReconstruction(choice: Bool) {
    isolated { defaults, store in
      defaults.set(!choice, forKey: TabBarPreference.key)
      defaults.set(!choice, forKey: quickKey)
      let first = TabBarWorkspace(defaults: defaults, store: store)
      defer { first.close() }
      first.tabs.toggleTabBar(for: first.quickID)
      #expect(first.tabs.showsTabBar(for: first.quickID) == choice)
      #expect(first.tabs.showsTabBar(for: first.mainID) == !choice)
      #expect(defaults.bool(forKey: TabBarPreference.key) == !choice)
      #expect(defaults.bool(forKey: quickKey) == choice)
      let next = TabBarWorkspace(defaults: defaults, store: store)
      defer { next.close() }
      #expect(next.tabs.showsTabBar(for: next.mainID) == !choice)
      #expect(next.tabs.showsTabBar(for: next.quickID) == choice)
    }
  }

  @Test("legacy false is respected and quick inherits it only once even when main changes before reconstruction")
  func legacyFalseIsInheritedOnce() {
    isolated { defaults, store in
      defaults.set(false, forKey: TabBarPreference.key)
      let first = TabBarWorkspace(defaults: defaults, store: store)
      defer { first.close() }
      #expect(!first.tabs.showsTabBar(for: first.mainID) && !first.tabs.showsTabBar(for: first.quickID))
      #expect(defaults.object(forKey: quickKey) as? Bool == false)
      first.tabs.toggleTabBar(for: nil)
      #expect(first.tabs.showsTabBar(for: first.mainID))
      #expect(!first.tabs.showsTabBar(for: first.quickID), "nil/lone compatibility cannot change quick's inherited choice")
      let next = TabBarWorkspace(defaults: defaults, store: store)
      defer { next.close() }
      #expect(next.tabs.showsTabBar(for: next.mainID))
      #expect(!next.tabs.showsTabBar(for: next.quickID))
    }
  }

  @Test("reveal exits zen and persists only the requesting host", arguments: [false, true])
  func hostRevealPersistsWithoutChangingOtherHost(quick: Bool) {
    isolated { defaults, store in
      defaults.set(false, forKey: TabBarPreference.key)
      defaults.set(false, forKey: quickKey)
      let first = TabBarWorkspace(defaults: defaults, store: store)
      defer { first.close() }
      let tab = SessionTab(preview: .local, known: first.tabs.known, name: "Preview", live: false)
      first.tabs.adopt(tab)
      first.focus(quick ? first.quickID : first.mainID)
      first.tabs.toggleZen()
      first.tabs.beginRenamingTerminal(tab.id)
      #expect(!first.tabs.zen)
      #expect(first.tabs.showsTabBar(for: first.mainID) == !quick)
      #expect(first.tabs.showsTabBar(for: first.quickID) == quick)
      first.tabs.toggleZen()
      #expect(!first.tabs.showsTabBar(for: first.mainID) && !first.tabs.showsTabBar(for: first.quickID))
      first.tabs.toggleZen()
      let next = TabBarWorkspace(defaults: defaults, store: store)
      defer { next.close() }
      #expect(next.tabs.showsTabBar(for: next.mainID) == !quick)
      #expect(next.tabs.showsTabBar(for: next.quickID) == quick)
    }
  }

  @Test("extra workspace instances keep runtime choices without persisting their random identity or changing main")
  func extraWorkspaceIsRuntimeOnly() {
    isolated { defaults, store in
      defaults.set(true, forKey: TabBarPreference.key)
      defaults.set(false, forKey: quickKey)
      let main = TabBarWorkspace(defaults: defaults, store: store)
      let extra = TabBarWorkspace(defaults: defaults, store: store, sharing: main.tabs.quickTerminal)
      defer { extra.close(); main.close() }
      extra.tabs.toggleTabBar(for: extra.mainID)
      #expect(!extra.tabs.showsTabBar(for: extra.mainID))
      #expect(defaults.bool(forKey: TabBarPreference.key))
      #expect(main.tabs.showsTabBar(for: main.mainID))
      main.tabs.toggleTabBar(for: main.mainID)
      extra.tabs.toggleTabBar(for: extra.mainID)
      #expect(extra.tabs.showsTabBar(for: extra.mainID))
      #expect(!main.tabs.showsTabBar(for: main.mainID))
      #expect(!defaults.bool(forKey: TabBarPreference.key), "extra's local toggle must not overwrite main's persisted choice")
      #expect(!defaults.bool(forKey: quickKey))
      #expect(!defaults.dictionaryRepresentation().keys.contains { $0.contains(extra.mainID.uuidString) })
    }
  }
}
#endif
