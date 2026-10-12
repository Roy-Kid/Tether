#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import TetherApp

  @Suite("Titlebar double-click")
  struct TitlebarDoubleClickTests {
    @Test("the choice in Desktop & Dock decides")
    func followsSetting() {
      #expect(TitlebarDoubleClick.action(setting: "Maximize", legacyMinimize: nil) == .zoom)
      #expect(TitlebarDoubleClick.action(setting: "Fill", legacyMinimize: nil) == .zoom)
      #expect(TitlebarDoubleClick.action(setting: "Minimize", legacyMinimize: nil) == .minimize)
      #expect(TitlebarDoubleClick.action(setting: "None", legacyMinimize: nil) == .nothing)
      // The current setting wins over the old switch when both are there.
      #expect(TitlebarDoubleClick.action(setting: "Maximize", legacyMinimize: true) == .zoom)
    }

    @Test("unset is the system default, or the older switch where it was set")
    func unset() {
      #expect(TitlebarDoubleClick.action(setting: nil, legacyMinimize: nil) == .zoom)
      #expect(TitlebarDoubleClick.action(setting: nil, legacyMinimize: false) == .zoom)
      #expect(TitlebarDoubleClick.action(setting: nil, legacyMinimize: true) == .minimize)
    }

    @Test("read from the defaults it is given")
    func readsDefaults() throws {
      let suite = "Tether.TitlebarDoubleClickTests.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set("None", forKey: TitlebarDoubleClick.actionKey)
      #expect(TitlebarDoubleClick.chosen(in: defaults) == .nothing)
    }

    @MainActor
    @Test("each choice does its one thing to the window")
    func performs() {
      let window = KeyedWindow.make()
      defer { window.close() }
      TitlebarDoubleClick.zoom.perform(on: window)
      TitlebarDoubleClick.minimize.perform(on: window)
      TitlebarDoubleClick.nothing.perform(on: window)
      #expect(window.zooms == 1)
      #expect(window.miniaturizes == 1)
    }
  }

  @MainActor
  @Suite("⌘W with nothing open")
  struct CloseWindowCommandTests {
    @Test("an empty window closes the window, and says so in the menu")
    func emptyClosesWindow() {
      let tabs = TabSet()
      #expect(tabs.closesWindow)
      #expect(tabs.canPerform(.closeTerminal))
      #expect(tabs.title(for: .closeTerminal) == "Close Window")
      tabs.perform(.closeTerminal)
      tabs.perform(.closeTerminal)
      #expect(tabs.windowCloseRequests == 2)
      tabs.perform(.closeTab)
      #expect(tabs.windowCloseRequests == 2, "⌥⌘W closes a tab, and there is none")
      tabs.perform(.closeWindow)
      #expect(tabs.windowCloseRequests == 3)
    }

    @Test("a palette is closed first, and the window stays")
    func paletteFirst() {
      let tabs = TabSet()
      tabs.perform(.commandMenu)
      #expect(tabs.palette != nil)
      #expect(tabs.title(for: .closeTerminal) == "Close Terminal")
      tabs.perform(.closeTerminal)
      #expect(tabs.palette == nil)
      #expect(tabs.windowCloseRequests == 0)
    }

    @Test("an open terminal is what ⌘W closes, never the window")
    func tabFirst() async throws {
      let tabs = TabSet(inspectActivity: { _ in .running(["vim"]) })
      tabs.adopt(SessionTab(preview: .local, known: KnownHosts(), name: "Terminal 1", live: true))
      #expect(!tabs.closesWindow)
      tabs.perform(.closeTerminal)
      #expect(tabs.windowCloseRequests == 0)
      #expect(tabs.tabs.count == 1)
      for _ in 0..<200 where tabs.pendingClose == nil { try await Task.sleep(for: .milliseconds(5)) }
      #expect(tabs.pendingClose == tabs.tabs.first?.id, "a live shell still asks first")
      #expect(tabs.pendingCloseVerb == "Close Terminal")
    }
  }

  /// The red button, ⌘W and the Dock, through the window the app draws.
  @MainActor
  @Suite("Closing the main window", .serialized)
  struct MainWindowCloseTests {
    @Test("a full-screen window leaves its Space before it is put away")
    func fullScreen() {
      #expect(MainWindowClose.action(fullScreen: false) == .hide)
      #expect(MainWindowClose.action(fullScreen: true) == .leaveFullScreenThenHide)
    }

    @Test("the red button puts the window away with its sessions, and the Dock brings it back")
    func closeHides() throws {
      let hosted = try HostedWorkspace(terminals: 1)
      defer { hosted.tearDown() }
      let window = hosted.window
      #expect(window.delegate is HideInsteadOfClose)

      window.performClose(nil)
      HostedWorkspace.settle(0.25)
      #expect(!window.isVisible)
      #expect(window.miniaturizes == 0)
      #expect(hosted.tabs.tabs.count == 1)
      #expect(hosted.tabs.tabs.first?.isLive == true)

      #expect(HideInsteadOfClose.reveal(window))
      #expect(window.isVisible)
      #expect(!HideInsteadOfClose.reveal(window), "a window already in front is left alone")
    }

    @Test("⌘W in an empty window closes it the way the red button does")
    func commandClosesEmptyWindow() throws {
      let hosted = try HostedWorkspace(terminals: 0)
      defer { hosted.tearDown() }
      #expect(hosted.window.isVisible)

      hosted.tabs.perform(.closeTerminal)
      HostedWorkspace.settle(0.25)
      #expect(!hosted.window.isVisible)
      #expect(hosted.window.miniaturizes == 0)
    }

    @Test("⇧⌘W puts the window away with its terminals still open")
    func commandClosesWindow() throws {
      let hosted = try HostedWorkspace(terminals: 1)
      defer { hosted.tearDown() }
      hosted.tabs.perform(.closeWindow)
      HostedWorkspace.settle(0.25)
      #expect(!hosted.window.isVisible)
      #expect(hosted.tabs.tabs.count == 1)
    }
  }
#endif
