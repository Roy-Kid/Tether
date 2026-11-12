#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TetherTestSupport
@testable import TetherApp

@MainActor
@Suite("Quick Terminal Placement", .serialized, .appKitEventLoop)
struct QuickTerminalPlacementTests {
  let minimum = NSSize(width: 760, height: 300)

  @Test("top and bottom span the width; bottom rests on the display's bottom edge")
  func topBottomGeometry() {
    let screen = NSRect(x: -1600, y: 924, width: 1600, height: 876)
    // Top: as it has always been — full width, hung from the top.
    #expect(QuickTerminalController.frame(
      in: screen, size: nil, minimum: minimum, placement: .top) ==
      NSRect(x: -1600, y: 1500, width: 1600, height: 300))
    // Bottom: the same shape, resting on the bottom edge.
    #expect(QuickTerminalController.frame(
      in: screen, size: nil, minimum: minimum, placement: .bottom) ==
      NSRect(x: -1600, y: 924, width: 1600, height: 300))
    // A remembered size comes back centred on the same edge.
    #expect(QuickTerminalController.frame(
      in: screen, size: NSSize(width: 1000, height: 600), minimum: minimum, placement: .bottom) ==
      NSRect(x: -1300, y: 924, width: 1000, height: 600))
    // Never below the minimum, never wider than the display.
    #expect(QuickTerminalController.frame(
      in: screen, size: NSSize(width: 400, height: 40), minimum: minimum, placement: .bottom) ==
      NSRect(x: -1180, y: 924, width: 760, height: 300))
  }

  @Test("side placements hug the side, spanning the height, centred when shorter")
  func sideGeometry() {
    let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    // Default: 40% of the width, the full height, hugging the edge.
    #expect(QuickTerminalController.frame(
      in: screen, size: nil, minimum: minimum, placement: .left) ==
      NSRect(x: 0, y: 0, width: 1024, height: 1440))
    #expect(QuickTerminalController.frame(
      in: screen, size: nil, minimum: minimum, placement: .right) ==
      NSRect(x: 1536, y: 0, width: 1024, height: 1440))
    // A dragged width is kept; a shorter panel centres vertically.
    #expect(QuickTerminalController.frame(
      in: screen, size: NSSize(width: 1000, height: 800), minimum: minimum, placement: .left) ==
      NSRect(x: 0, y: 320, width: 1000, height: 800))
    // Negative origins are respected; the 40% default still respects the minimum.
    let portrait = NSRect(x: -1440, y: -1120, width: 1440, height: 2560)
    #expect(QuickTerminalController.frame(
      in: portrait, size: nil, minimum: minimum, placement: .right) ==
      NSRect(x: -760, y: -1120, width: 760, height: 2560))
  }

  @Test("floating is centered, keeps a dragged size, and never snaps to an edge")
  func floatingGeometry() {
    let screen = NSRect(x: -1600, y: 924, width: 1600, height: 876)
    #expect(QuickTerminalController.frame(
      in: screen, size: nil, minimum: minimum, placement: .floating) ==
      NSRect(x: -1280, y: 1143, width: 960, height: 438))
    #expect(QuickTerminalController.frame(
      in: screen, size: NSSize(width: 900, height: 520), minimum: minimum, placement: .floating) ==
      NSRect(x: -1250, y: 1102, width: 900, height: 520))
  }

  @Test("frames are whole points, even on odd-sized displays, and tiny displays clamp safely")
  func integralAndTiny() {
    let odd = NSRect(x: 0, y: 0, width: 999, height: 777)
    for placement in QuickTerminalPlacement.allCases {
      let frame = QuickTerminalController.frame(
        in: odd, size: nil, minimum: NSSize(width: 10, height: 10), placement: placement)
      #expect(frame.integral == frame)
      #expect(odd.contains(frame))
    }
    let tiny = NSRect(x: 0, y: 0, width: 800, height: 400)
    for placement in QuickTerminalPlacement.allCases {
      let frame = QuickTerminalController.frame(
        in: tiny, size: nil, minimum: NSSize(width: 760, height: 520), placement: placement)
      #expect(tiny.contains(frame))
      #expect(frame.width >= 760 || placement == .floating)
    }
  }

  @Test("a fixed display wins over the pointer; a missing one falls back without discarding the choice")
  func displayChoiceResolution() {
    let displays = [
      QuickDisplay(id: "aaaaaa", name: "Studio"),
      QuickDisplay(id: "bbbbbb", name: "Cinema"),
    ]
    #expect(QuickDisplayChoice.target(fixedID: "bbbbbb", pointerID: "aaaaaa", displays: displays) == "bbbbbb")
    #expect(QuickDisplayChoice.target(fixedID: "gone", pointerID: "aaaaaa", displays: displays) == "aaaaaa")
    #expect(QuickDisplayChoice.target(fixedID: nil, pointerID: "aaaaaa", displays: displays) == "aaaaaa")
    // Neither: the caller picks the main or any display.
    #expect(QuickDisplayChoice.target(fixedID: "gone", pointerID: nil, displays: displays) == nil)
    #expect(QuickDisplayChoice.target(fixedID: "gone", pointerID: "zz", displays: displays) == nil)
    #expect(QuickDisplayChoice.target(fixedID: nil, pointerID: nil, displays: []) == nil)
  }

  @Test("same-named displays are told apart by a stable suffix")
  func disambiguation() {
    let named = QuickDisplayCatalog.disambiguate([
      QuickDisplay(id: "uuid-aaaaaa", name: "Studio"),
      QuickDisplay(id: "uuid-bbbbbb", name: "Studio"),
      QuickDisplay(id: "uuid-cccccc", name: "Cinema"),
    ])
    #expect(named[0].name == "Studio (aaaaaa)")
    #expect(named[1].name == "Studio (bbbbbb)")
    #expect(named[2].name == "Cinema")
  }

  @Test("attached displays have stable, unique, non-empty identities")
  func currentDisplaysAreIdentifiable() {
    let displays = QuickDisplayCatalog.current()
    #expect(!displays.isEmpty, "a test machine has at least one display")
    #expect(displays.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
    #expect(Set(displays.map(\.id)).count == displays.count)
    #expect(displays.map(\.id) == QuickDisplayCatalog.current().map(\.id), "stable across reads")
  }

  @Test("placement and display choices persist; malformed values fall back to the defaults")
  func choicePersistence() throws {
    let suite = "quick-placement-prefs.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    defer { controller.stop() }
    #expect(controller.placement == .top)
    controller.placement = .left
    controller.displayID = "uuid-aaaaaa"
    #expect(defaults.string(forKey: "quickTerminal.placement") == "left")
    #expect(defaults.string(forKey: "quickTerminal.display") == "uuid-aaaaaa")
    controller.displayID = nil
    #expect(defaults.object(forKey: "quickTerminal.display") == nil)

    let malformedSuite = "\(suite)-malformed"
    let malformed = try #require(UserDefaults(suiteName: malformedSuite))
    defer { malformed.removePersistentDomain(forName: malformedSuite) }
    malformed.set("sideways", forKey: "quickTerminal.placement")
    malformed.set("not a display id", forKey: "quickTerminal.display")
    let fallenBack = QuickTerminalController(defaults: malformed)
    defer { fallenBack.stop() }
    #expect(fallenBack.placement == .top)
    #expect(fallenBack.displayID == "not a display id", "kept, and simply matches nothing")
  }

  @Test("each placement remembers its own size; the top placement keeps its existing keys")
  func perModeSizes() throws {
    let suite = "quick-placement-sizes.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    controller.attach(panel: panel)

    // A previous launch stored the top placement's size: a fresh
    // controller reads it, and the top placement keeps these keys.
    defaults.set(800.0, forKey: "quickTerminal.width")
    defaults.set(420.0, forKey: "quickTerminal.height")
    controller.placement = .bottom   // bottom's own memory starts empty
    controller.placement = .top
    controller.toggle()
    #expect(panel.frame.size == NSSize(width: 800, height: 420))

    // A bottom drag remembers bottom keys, and the legacy keys survive.
    controller.placement = .bottom
    panel.setFrame(NSRect(x: 100, y: 500, width: 900, height: 500), display: false)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: panel)
    controller.hide()
    #expect(defaults.double(forKey: "quickTerminal.width.bottom") == 900)
    #expect(defaults.double(forKey: "quickTerminal.height.bottom") == 500)
    #expect(defaults.double(forKey: "quickTerminal.width") == 800, "the top placement's keys are its own")

    // Each mode comes back with its own shape.
    controller.toggle()
    #expect(panel.frame.size == NSSize(width: 900, height: 500))
    #expect(panel.frame.minY == panel.screen?.visibleFrame.minY, "bottom rests on the edge")
    controller.placement = .top
    #expect(panel.frame.size == NSSize(width: 800, height: 420))
    #expect(panel.frame.maxY == panel.screen?.visibleFrame.maxY, "top hangs from the edge")

    // Reset restores the current mode's default and touches no other mode.
    controller.placement = .bottom
    controller.resetSize()
    #expect(defaults.object(forKey: "quickTerminal.width.bottom") == nil)
    #expect(defaults.double(forKey: "quickTerminal.width") == 800)
    let screen = try #require(panel.screen)
    #expect(panel.frame == QuickTerminalController.frame(
      in: screen.visibleFrame, size: nil, minimum: panel.minSize, placement: .bottom))
  }

  @Test("a fixed display that is gone falls back to the pointer's display and the choice is kept")
  func absentFixedDisplay() throws {
    let suite = "quick-placement-absent.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    controller.attach(panel: panel)
    controller.displayID = "display-that-is-not-attached"
    controller.toggle()
    #expect(controller.isShown, "falls back instead of failing to show")
    #expect(defaults.string(forKey: "quickTerminal.display") == "display-that-is-not-attached",
      "the preference survives until the display comes back")
    controller.hide()
    controller.displayID = nil
  }

  @Test("the floating placement keeps its position across summons and never snaps to an edge")
  func floatingKeepsItsPlace() throws {
    let suite = "quick-placement-floating.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    controller.attach(panel: panel)
    controller.placement = .floating
    controller.toggle()
    let moved = NSRect(x: 150, y: 260, width: 720, height: 480)
    panel.setFrame(moved, display: false)
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: panel)
    #expect(panel.frame == moved.integral, "a screen change does not snap a floating panel")
    controller.toggle()
    controller.toggle()
    #expect(panel.frame == moved.integral, "a summon keeps the position it was given")
  }

  @Test("screen-parameter changes re-place a shown panel; stop unregisters; re-attaching restarts")
  func screenParametersObserver() throws {
    let suite = "quick-placement-observer.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let main = WorkspaceWindow(hosting: Color.clear, autosaveName: nil)
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { main.close(); panel.close() }
    // The production wiring: listening starts from attaching the main window.
    controller.attach(to: main)
    controller.attach(panel: panel)
    controller.placement = .top
    controller.toggle()
    let screen = try #require(panel.screen)
    let placed = QuickTerminalController.frame(
      in: screen.visibleFrame, size: nil, minimum: panel.minSize, placement: .top)
    #expect(panel.frame == placed)
    let elsewhere = NSRect(x: 20, y: 20, width: 600, height: 400).integral

    // The panel is somewhere else; a display change re-hangs it.
    panel.setFrame(elsewhere, display: false)
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    #expect(panel.frame == placed, "the callback re-placed the panel")

    // Stopped, the same notification no longer moves it.
    controller.stop()
    panel.setFrame(elsewhere, display: false)
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    #expect(panel.frame == elsewhere, "stop unregisters the observer")

    // Re-attaching the same windows restarts everything.
    controller.attach(to: main)
    controller.attach(panel: panel)
    controller.toggle()
    #expect(controller.isShown)
    panel.setFrame(elsewhere, display: false)
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    #expect(panel.frame == placed, "a re-attached controller observes again")
    controller.stop()
  }

  @Test("a floating frame is kept only on an unchanged basis that still fits")
  func frameKeepingPolicy() {
    let basis = QuickTerminalController.FrameBasis(placement: .floating, targetID: "a")
    let visible = NSRect(x: 0, y: 0, width: 500, height: 500)
    let inside = NSRect(x: 10, y: 10, width: 100, height: 100)
    let outside = NSRect(x: 400, y: 10, width: 200, height: 100)
    #expect(QuickTerminalController.shouldKeepFrame(
      current: basis, requested: basis, frame: inside, visibleFrame: visible))
    // A frame that no longer fits (a smaller visible frame) is recomputed.
    #expect(!QuickTerminalController.shouldKeepFrame(
      current: basis, requested: basis, frame: outside, visibleFrame: visible))
    // A basis that was never placed, or any change to it, re-places.
    #expect(!QuickTerminalController.shouldKeepFrame(
      current: nil, requested: basis, frame: inside, visibleFrame: visible))
    #expect(!QuickTerminalController.shouldKeepFrame(
      current: basis, requested: QuickTerminalController.FrameBasis(placement: .floating, targetID: "b"),
      frame: inside, visibleFrame: visible))
    #expect(!QuickTerminalController.shouldKeepFrame(
      current: basis, requested: QuickTerminalController.FrameBasis(placement: .top, targetID: "a"),
      frame: inside, visibleFrame: visible))
    // Edge placements always re-hang, even on an unchanged basis.
    #expect(!QuickTerminalController.shouldKeepFrame(
      current: QuickTerminalController.FrameBasis(placement: .top, targetID: "a"),
      requested: QuickTerminalController.FrameBasis(placement: .top, targetID: "a"),
      frame: inside, visibleFrame: visible))
  }

  @Test("the first summon honors the floating placement's geometry, centered")
  func floatingFirstShow() throws {
    let suite = "quick-placement-first-show.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    controller.attach(panel: panel)
    controller.placement = .floating
    controller.toggle()
    let screen = try #require(panel.screen)
    #expect(panel.frame == QuickTerminalController.frame(
      in: screen.visibleFrame, size: nil, minimum: panel.minSize, placement: .floating))
  }

  @Test("switching placements re-hangs the panel in each mode's shape")
  func placementTransitions() throws {
    let suite = "quick-placement-transitions.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    controller.attach(panel: panel)
    defaults.set(800.0, forKey: "quickTerminal.width")
    defaults.set(420.0, forKey: "quickTerminal.height")

    controller.placement = .top
    controller.toggle()
    #expect(panel.frame.size == NSSize(width: 800, height: 420))
    #expect(panel.frame.maxY == panel.screen?.visibleFrame.maxY)

    let screen = try #require(panel.screen)
    let floating = QuickTerminalController.frame(
      in: screen.visibleFrame, size: nil, minimum: panel.minSize, placement: .floating)
    controller.placement = .floating
    #expect(panel.frame == floating, "top → floating takes the floating shape, not the top rect")
    controller.placement = .left
    #expect(panel.frame == QuickTerminalController.frame(
      in: screen.visibleFrame, size: nil, minimum: panel.minSize, placement: .left))
    controller.placement = .floating
    #expect(panel.frame == floating, "floating again, still its own shape")
  }

  @Test("a floating size a previous launch dragged comes back on a fresh controller")
  func floatingSavedSizeFreshController() throws {
    let suite = "quick-placement-floating-memory.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { panel.close() }
    first.attach(panel: panel)
    first.placement = .floating
    first.toggle()
    panel.setFrame(NSRect(x: 200, y: 300, width: 720, height: 480), display: false)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: panel)
    first.hide()
    first.stop()

    let next = QuickTerminalController(defaults: defaults)
    defer { next.stop() }
    next.attach(panel: panel)
    next.placement = .floating
    next.toggle()
    let screen = try #require(panel.screen)
    #expect(panel.frame == QuickTerminalController.frame(
      in: screen.visibleFrame, size: NSSize(width: 720, height: 480), minimum: panel.minSize,
      placement: .floating))
  }

  @Test("reset restores the floating default whether the panel is shown or hidden")
  func resetFloating() throws {
    let suite = "quick-placement-reset.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = QuickTerminalController(defaults: defaults)
    let panel = KeyedQuickPanel(hosting: Color.clear)
    defer { controller.stop(); panel.close() }
    controller.attach(panel: panel)
    controller.placement = .floating
    controller.toggle()
    let screen = try #require(panel.screen)
    let dragged = NSRect(x: 200, y: 300, width: 720, height: 480).integral
    panel.setFrame(dragged, display: false)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: panel)
    #expect(defaults.object(forKey: "quickTerminal.width.floating") != nil)

    // Shown: the default shape comes back at once.
    controller.resetSize()
    #expect(defaults.object(forKey: "quickTerminal.width.floating") == nil)
    #expect(panel.frame == QuickTerminalController.frame(
      in: screen.visibleFrame, size: nil, minimum: panel.minSize, placement: .floating))

    // Hidden: the next summon is the default shape.
    controller.hide()
    panel.setFrame(dragged, display: false)
    controller.resetSize()
    controller.toggle()
    #expect(panel.frame == QuickTerminalController.frame(
      in: screen.visibleFrame, size: nil, minimum: panel.minSize, placement: .floating))
  }
}
#endif
