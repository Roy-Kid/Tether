#if os(macOS)
  import AppKit
  import Foundation
  import Testing
  import TetherTestSupport
  import SwiftUI

  @testable import TetherApp

  @Suite("Titlebar double-click", .appKitEventLoop)
  struct TitlebarDoubleClickTests {

  }

  @MainActor
  @Suite("⌘W with nothing open", .appKitEventLoop)
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

  /// The running app's choice, put back when the test ends. A machine that
  /// has already chosen Quit must not make these tests quit the runner.
  @MainActor
  private func withClosePreference(_ value: String, _ body: () throws -> Void) rethrows {
    let defaults = UserDefaults.standard
    let saved = defaults.object(forKey: CloseWindowPreference.key)
    defaults.set(value, forKey: CloseWindowPreference.key)
    defer {
      if let saved {
        defaults.set(saved, forKey: CloseWindowPreference.key)
      } else {
        defaults.removeObject(forKey: CloseWindowPreference.key)
      }
    }
    try body()
  }

  /// The red button, ⌘W and the Dock, through the window the app draws.
  @MainActor
  @Suite("Closing the main window", .serialized, .appKitEventLoop)
  struct MainWindowCloseTests {
    @Test("Hide puts the window away with its sessions, and showing it brings it back")
    func closeHides() throws {
      try withClosePreference(CloseWindowPreference.menuBar) {
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
    }

    @Test("Quit leaves the window up until the app itself quits")
    func quitLeavesTheWindow() throws {
      try withClosePreference(CloseWindowPreference.quit) {
        let hosted = try HostedWorkspace(terminals: 1)
        defer { hosted.tearDown() }
        hosted.window.performClose(nil)
        HostedWorkspace.settle(0.25)
        #expect(hosted.window.isVisible)
        #expect(hosted.tabs.tabs.first?.isLive == true)
        #expect(!AppPresence.isTether)
      }
    }

    @Test("Hide leaves the Dock only when nothing else is showing")
    func dockFollowsTheSetting() {
      #expect(CloseWindowPreference.default == CloseWindowPreference.menuBar)
      #expect(MainWindowClose.action(fullScreen: false, setting: CloseWindowPreference.quit) == .quit)
      #expect(MainWindowClose.action(fullScreen: true, setting: CloseWindowPreference.quit) == .quit)
      #expect(MainWindowClose.action(fullScreen: false, setting: CloseWindowPreference.menuBar) == .hide)
      #expect(MainWindowClose.action(fullScreen: true, setting: "elsewhere") == .leaveFullScreenThenHide)
      #expect(AppPresence.hidesDock(setting: CloseWindowPreference.menuBar, mainVisible: false, otherVisible: false))
      #expect(!AppPresence.hidesDock(setting: CloseWindowPreference.menuBar, mainVisible: false, otherVisible: true))
      #expect(!AppPresence.hidesDock(setting: CloseWindowPreference.quit, mainVisible: false, otherVisible: false))
      #expect(!AppPresence.hidesDock(setting: CloseWindowPreference.menuBar, mainVisible: true, otherVisible: false))
      #expect(QuickTerminalController.wantsMenuBarIcon(enabled: false, preference: false, holdingForHide: true, hasWindow: true))
      #expect(!QuickTerminalController.wantsMenuBarIcon(enabled: true, preference: false, holdingForHide: false, hasWindow: true))
      #expect(QuickTerminalController.wantsMenuBarIcon(enabled: true, preference: true, holdingForHide: false, hasWindow: true))
      #expect(!QuickTerminalController.wantsMenuBarIcon(enabled: true, preference: true, holdingForHide: true, hasWindow: false))
    }
  }
#endif

#if os(macOS)
  @Suite("Workspace background preferences", .appKitEventLoop)
  struct WorkspaceAppearanceTests {

  }
#endif
