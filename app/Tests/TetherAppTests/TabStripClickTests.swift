#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import TetherTestSupport
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

    @MainActor
    func tearDown() {
      window.delegate = nil
      window.close()
      AppPresence.returnToDock()
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
  @Suite("Tab drag gestures")
  struct TabDragGestureTests {
    @Test("a drag on a chip reorders, and a drag on a terminal splits")
    func distinguishesReorderFromSplit() {
      #expect(TabDrag.reorder(x: 10, y: 8, width: 80, height: 24, vertical: false) == .reorder(before: true))
      #expect(TabDrag.reorder(x: 50, y: 8, width: 80, height: 24, vertical: false) == .reorder(before: false))
      // A sidebar chip is wider than it is tall. The strip, not the chip, says which way.
      #expect(TabDrag.reorder(x: 40, y: 8, width: 180, height: 36, vertical: true) == .reorder(before: true))
      #expect(TabDrag.reorder(x: 40, y: 20, width: 180, height: 36, vertical: true) == .reorder(before: false))
      #expect(TabDrag.reorder(x: 0, y: 0, width: 0, height: 24, vertical: false) == nil)

      #expect(TabDrag.split(x: 20, y: 8, width: 180, height: 36) == .split(.left))
      #expect(TabDrag.split(x: 120, y: 8, width: 180, height: 36) == .split(.right))
      #expect(TabDrag.split(x: 10, y: 10, width: 40, height: 80) == .split(.up))
      #expect(TabDrag.split(x: 10, y: 50, width: 40, height: 80) == .split(.down))
      #expect(TabDrag.split(x: 0, y: 0, width: 0, height: 24) == nil)
      let pane = CGRect(x: 0, y: 0, width: 200, height: 100)
      #expect(TabDrag.mark(.split(.left), in: pane, vertical: false).rect == CGRect(x: 0, y: 0, width: 100, height: 100))
      #expect(TabDrag.mark(.split(.up), in: pane, vertical: false).rect == CGRect(x: 0, y: 50, width: 200, height: 50))
    }
  }

  @MainActor
  @Suite("Tab strip clicks", .serialized, .appKitEventLoop)
  struct TabStripClickTests {
    @Test("the plus beside the tab strip requests a new tab without dragging the window")
    func plusCreatesTab() throws {
      let window = KeyedWindow.make()
      defer { window.close() }
      let suite = "Tether.NewTab.\(UUID())"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let tabs = TabSet(defaults: defaults)
      window.contentView = NSHostingView(rootView:
        VStack(spacing: 0) {
          WorkspaceTabBar(tabs: tabs, onClose: { _ in })
          Spacer()
        })
      window.orderFront(nil)
      HostedWorkspace.settle(0.5)
      let (strip, frames) = try catcher(in: window)
      let plus = try #require(frames.values.first, "the empty strip still exposes its add button")
      let point = windowPoint(plus.midX, plus.midY, in: strip)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
      }
      HostedWorkspace.settle(0.25)
      #expect(tabs.intent == .newTab)
      #expect(window.drags == 0)
    }

    @Test("a merged terminal shows its tab, and the drop target fills the pane")
    func splitPanesShowTheirTabs() throws {
      let hosted = try HostedWorkspace(terminals: 2)
      defer { hosted.tearDown() }
      let ids = hosted.tabs.tabs.map(\.id)
      let dragged = try #require(ids.last)
      let target = try #require(ids.first)
      #expect(hosted.tabs.place(dragged, beside: target, edge: .right))
      HostedWorkspace.settle(0.6)

      let content = try #require(hosted.window.contentView)
      let strip = try #require(catcher(in: content))
      let stripBox = strip.convert(strip.bounds, to: content)
      let droppers = views(in: content).filter { String(describing: type(of: $0)).contains("Dropper") }
      #expect(droppers.count == 2)
      for dropper in droppers {
        #expect(dropper.bounds.width > 40)
        #expect(dropper.bounds.height > 40)
        // The tab is a row between the strip and the terminal. The drop
        // target is the terminal, so it starts a tab's height below the strip.
        let box = dropper.convert(dropper.bounds, to: content)
        let gap = verticalGap(stripBox, box)
        #expect(gap > Chrome.tab - 8, "gap \(gap)")
        #expect(gap < Chrome.tab + 16, "gap \(gap)")
      }

      hosted.tabs.select(target)
      #expect(hosted.tabs.selected == target)
      #expect(hosted.tabs.workspaceSplit?.ids.contains(target) == true)
      #expect(hosted.tabs.workspaceSplit?.ids.contains(dragged) == true)
    }

    /// A pane tab is SwiftUI drawn by the hosting view, so the window's
    /// accessibility tree does not carry its title. The bitmap does.
    @Test("a split pane's tab draws its name, its selection rule and its mark")
    func splitPaneTabDrawsItsNameRuleAndMark() throws {
      let mark = PluginTabIndicator(
        target: PluginTerminalIdentity(host: "studio.local", terminal: "/dev/ttys001"),
        color: 0xFF2B_D6, label: "Running")
      let image = try renderPaneTabs([
        ("Terminal 1", false, nil),
        ("Terminal 2", false, nil),
        ("Terminal 1", true, nil),
        ("Terminal 1", true, mark),
      ])
      let rowHeight = image.pixelsHigh / 4
      #expect(rowHeight >= Int(Chrome.tab))
      #expect(rowHeight <= Int(Chrome.tab) * 3)

      let scores = (0..<4).map { magentaScore(image, row: $0, rowHeight: rowHeight) }
      let dotted = try #require(scores.enumerated().max { $0.element < $1.element }?.offset)
      #expect(scores[dotted] > 80, "scores \(scores)")
      let row: (Int) -> Int = { dotted == 3 ? $0 : 3 - $0 }

      #expect(differing(image, row(0), image, row(1), rowHeight: rowHeight) > 20, "the two names differ")
      let edge = ruleEdge(image, row: row(2), rowHeight: rowHeight)
      let selectedChroma = edgeChroma(image, row: row(2), rowHeight: rowHeight, edge: edge)
      let plainChroma = edgeChroma(image, row: row(0), rowHeight: rowHeight, edge: edge)
      #expect(selectedChroma > plainChroma + 30, "selected \(selectedChroma) plain \(plainChroma)")
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

    private func textField(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field.isEditable { return field }
      return view.subviews.lazy.compactMap { textField(in: $0) }.first
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

    private func views(in view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { views(in: $0) }
    }

    /// The space between two rectangles that share a coordinate space.
    /// Zero when they overlap. Independent of which edge is up.
    private func verticalGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
      if a.maxY <= b.minY { return b.minY - a.maxY }
      if b.maxY <= a.minY { return a.minY - b.maxY }
      return 0
    }

    private func renderPaneTabs(
      _ rows: [(String, Bool, PluginTabIndicator?)]
    ) throws -> NSBitmapImageRep {
      let height = Chrome.tab * CGFloat(rows.count)
      let root = VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          SplitPaneTab(
            title: row.0, symbol: "terminal", indicator: row.2,
            disconnected: false, selected: row.1, onSelect: {})
            .frame(width: 220, height: Chrome.tab)
        }
      }
      .environment(\.colorScheme, .light)
      .frame(width: 220, height: height)

      let view = NSHostingView(rootView: root)
      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 220, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = view
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      HostedWorkspace.settle(0.35)
      view.layoutSubtreeIfNeeded()
      let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: image)
      return image
    }

    private enum BandEdge { case start, end }

    private func sample(_ image: NSBitmapImageRep, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
      var pixel = [Int](repeating: 0, count: 4)
      image.getPixel(&pixel, atX: x, y: y)
      let unit = image.bitsPerSample > 8 ? 257 : 1
      return (pixel[0] / unit, pixel[1] / unit, pixel[2] / unit)
    }

    private func magentaScore(_ image: NSBitmapImageRep, row: Int, rowHeight: Int) -> Double {
      let y0 = row * rowHeight
      let inset = max(2, rowHeight / 8)
      let xLimit = max(1, image.pixelsWide / 5)
      var best = 0.0
      for y in (y0 + inset)..<(y0 + rowHeight - inset) {
        for x in 0..<xLimit {
          let pixel = sample(image, x: x, y: y)
          best = max(best, Double(pixel.r + pixel.b) / 2 - Double(pixel.g))
        }
      }
      return best
    }

    private func differing(
      _ image: NSBitmapImageRep, _ left: Int, _ other: NSBitmapImageRep, _ right: Int, rowHeight: Int
    ) -> Int {
      var count = 0
      for y in 0..<rowHeight {
        for x in 0..<image.pixelsWide {
          let a = sample(image, x: x, y: left * rowHeight + y)
          let b = sample(other, x: x, y: right * rowHeight + y)
          let delta = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
          if delta > 24 { count += 1 }
        }
      }
      return count
    }

    private func ruleEdge(_ image: NSBitmapImageRep, row: Int, rowHeight: Int) -> BandEdge {
      let start = edgeChroma(image, row: row, rowHeight: rowHeight, edge: .start)
      let end = edgeChroma(image, row: row, rowHeight: rowHeight, edge: .end)
      return start > end ? .start : .end
    }

    private func edgeChroma(
      _ image: NSBitmapImageRep, row: Int, rowHeight: Int, edge: BandEdge
    ) -> Double {
      let band = min(4, rowHeight / 2)
      let y0 = row * rowHeight + (edge == .start ? 0 : rowHeight - band)
      var total = 0.0
      var count = 0
      for y in y0..<(y0 + band) {
        for x in 0..<image.pixelsWide {
          let pixel = sample(image, x: x, y: y)
          total += Double(max(pixel.r, pixel.g, pixel.b) - min(pixel.r, pixel.g, pixel.b))
          count += 1
        }
      }
      return count == 0 ? 0 : total / Double(count)
    }
  }
#endif
