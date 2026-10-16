#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import Tether
  import TetherPluginHost
  import TetherPluginKit

  @testable import TetherApp

  /// A window that answers as the key window, which a test process cannot
  /// otherwise make one: the titlebar treats a click on a window in the
  /// background differently.
  ///
  /// A drag is counted rather than run: `performDrag` tracks the real mouse
  /// until its button comes up, and a test has no mouse to let go of.
  final class KeyedWindow: NSWindow {
    private(set) var drags = 0
    private(set) var zooms = 0
    private(set) var miniaturizes = 0

    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override func performDrag(with event: NSEvent) { drags += 1 }
    override func zoom(_ sender: Any?) { zooms += 1 }
    override func miniaturize(_ sender: Any?) { miniaturizes += 1 }

    static func make() -> KeyedWindow {
      let window = KeyedWindow(
        contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      return window
    }
  }

  /// The whole window, as the app shows it, over a library in a directory of
  /// its own and secrets that never reach the keychain.
  @MainActor
  struct HostedWorkspace {
    let window = KeyedWindow.make()
    let tabs: TabSet
    private let directory: URL
    private let suite: String

    init(terminals: Int) throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let store = HostStore(
        location: directory.appending(path: "config"), secrets: MemorySecrets(),
        credentials: DeviceCredentialStore(secrets: MemorySecrets()),
        databaseURL: directory.appending(path: "identity.sqlite"))
      suite = "Tether.HostedWorkspace.\(UUID())"
      tabs = TabSet(defaults: UserDefaults(suiteName: suite)!)
      for index in 0..<terminals {
        tabs.adopt(SessionTab(preview: .local, known: KnownHosts(), name: "Terminal \(index + 1)", live: true))
      }
      var installed: InstalledPlugins?
      window.contentView = NSHostingView(
        rootView: RootView(
          store: store, tabs: tabs, registry: PluginRegistry(), secrets: MemorySecrets(),
          plugins: PluginAPI(consent: DialogConsent()),
          installedPlugins: Binding(get: { installed }, set: { installed = $0 })))
      window.orderFront(nil)
      Self.settle(1.5)
    }

    func tearDown() {
      window.close()
      UserDefaults().removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }

    static func settle(_ seconds: TimeInterval) {
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Down and up at a point in window coordinates, the way a person's
    /// click arrives: through the window, not to a view.
    func click(at point: NSPoint, count: Int = 1) {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(
          NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!)
      }
      Self.settle(0.25)
    }
  }

  /// The tab strip is in the titlebar, under AppKit's own handling and above
  /// the split view's panes. A click is sent through the window, the way a
  /// person's arrives, rather than to the strip.
  @MainActor
  @Suite("Tab strip clicks", .serialized)
  struct TabStripClickTests {
    @Test("a click on a tab in the titlebar switches to it")
    func clickSwitches() throws {
      let hosted = try HostedWorkspace(terminals: 2)
      defer { hosted.tearDown() }
      let ids = hosted.tabs.visibleIDs
      #expect(hosted.tabs.selectedWorkspaceID == ids[1])

      let (strip, frames) = try catcher(in: hosted.window)
      let chip = try #require(frames[ids[0]], "the strip knows where the first tab is")
      hosted.click(at: windowPoint(chip.midX, chip.midY, in: strip))
      #expect(hosted.tabs.selectedWorkspaceID == ids[0])
      #expect(hosted.window.drags == 0)
    }

    /// The strip's scroll view takes the width the tabs do not need, and the
    /// catcher lies over all of it. A press there that misses every tab is a
    /// press on the titlebar, and a titlebar moves its window.
    @Test("a press on the strip beside the tabs drags the window")
    func emptyStripDrags() throws {
      let hosted = try HostedWorkspace(terminals: 2)
      defer { hosted.tearDown() }
      let selected = hosted.tabs.selectedWorkspaceID

      let (strip, frames) = try catcher(in: hosted.window)
      let end = try #require(frames.values.map(\.maxX).max())
      #expect(strip.bounds.width > end + 40, "the strip runs on past its last tab")
      let midY = try #require(frames.values.first).midY
      hosted.click(at: windowPoint(end + 30, midY, in: strip))

      #expect(hosted.window.drags == 1)
      #expect(hosted.tabs.selectedWorkspaceID == selected)
    }

    private func catcher(in window: NSWindow) throws -> (NSView, [UUID: CGRect]) {
      let strip = try #require(window.contentView.flatMap(catcher(in:)))
      let frames =
        Mirror(reflecting: strip).children.first { $0.label == "frames" }?.value as? [UUID: CGRect] ?? [:]
      return (strip, frames)
    }

    /// SwiftUI frames are top-left; the strip may be either way up.
    private func windowPoint(_ x: CGFloat, _ y: CGFloat, in strip: NSView) -> NSPoint {
      strip.convert(NSPoint(x: x, y: strip.isFlipped ? y : strip.bounds.height - y), to: nil)
    }

    private func catcher(in view: NSView) -> NSView? {
      if String(describing: type(of: view)) == "Catcher" { return view }
      return view.subviews.lazy.compactMap(catcher(in:)).first
    }
  }
#endif
