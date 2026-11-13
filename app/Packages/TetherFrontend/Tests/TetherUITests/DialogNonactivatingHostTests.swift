#if os(macOS)
import AppKit
import Testing
import TetherTestSupport
@testable import TetherUI

/// Only test-owned, off-screen windows and in-memory input. No app model,
/// credential store, SSH connection, or activation of another application.
@MainActor
@Suite("Dialog nonactivating host", .serialized, .appKitEventLoop)
struct DialogNonactivatingHostTests {
  private final class HostPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
  }

  private func settle(until condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
  }

  private func fields(in view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField, field.isEditable { return [field] }
    return view.subviews.flatMap { fields(in: $0) }
  }

  @Test("Explicit panel host keeps confirmation and password surfaces nonactivating", arguments: [false, true])
  func panelHost(password: Bool) async throws {
    let main = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    let panel = HostPanel(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 300),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.hidesOnDeactivate = false
    main.orderFrontRegardless()
    panel.orderFrontRegardless()
    let anchor = DialogAnchor(window: panel)
    let surface = PlatformDialogSurface()
    let queue = DialogQueue(surface: surface)
    var presented = 0
    var completed = 0
    var dismissed = 0
    var events: [String] = []
    var visibleChild: NSWindow?
    var secret = ""
    let dialog = password
      ? Dialog.input("Preview password", field: Dialog.Field("Password", kind: .password),
        verb: "Continue") { secret = $0; completed += 1; events.append("completed") }
      : Dialog.confirm("Preview confirmation", verb: "Continue") { completed += 1; events.append("completed") }
    let task = Task {
      await queue.ask(dialog, in: anchor, shown: { presented += 1; events.append("presented") }, didDismiss: {
        dismissed += 1
        events.append("dismissed")
        #expect(visibleChild?.isVisible == false)
        #expect(visibleChild?.sheetParent == nil && visibleChild?.parent == nil)
      })
    }
    defer { task.cancel(); surface.withdraw(); panel.orderOut(nil); main.orderOut(nil) }
    try await settle { panel.attachedSheet != nil || panel.childWindows?.isEmpty == false }
    let child = try #require(panel.attachedSheet ?? panel.childWindows?.first)
    visibleChild = child
    #expect(presented == 1)
    #expect(main.attachedSheet == nil && main.childWindows?.isEmpty != false)
    #expect(child.sheetParent === panel || child.parent === panel)
    #expect(child is NSPanel)
    #expect(child.styleMask.contains(.nonactivatingPanel), "the native sheet must inherit nonactivating input semantics")
    if password {
      let field = try #require(fields(in: child.contentView!).first)
      #expect(field is NSSecureTextField)
      #expect(child.initialFirstResponder === field)
      child.makeFirstResponder(field)
      let editor = try #require(field.currentEditor() as? NSTextView)
      #expect(child.firstResponder === editor)
      editor.selectAll(nil)
      editor.insertText("memory-only-preview", replacementRange: editor.selectedRange())
    }
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: child.windowNumber, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    #expect(surface.route(key) == nil)
    #expect(await task.value?.isAffirmative == true)
    try await settle { dismissed == 1 }
    #expect(!child.isVisible && child.sheetParent == nil && child.parent == nil)
    #expect(presented == 1 && completed == 1 && dismissed == 1)
    #expect(events == ["presented", "completed", "dismissed"])
    #expect(secret == (password ? "memory-only-preview" : ""))
  }

  @Test("An explicitly pinned panel anchor cannot be hijacked or fall back to another window")
  func explicitAnchorOwnership() async {
    let panel = HostPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel],
      backing: .buffered, defer: false)
    let other = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    other.orderFrontRegardless()
    let anchor = DialogAnchor(window: panel)
    let observer = DialogAnchorReader.Reader()
    observer.anchor = anchor
    other.contentView = observer
    observer.claim()
    #expect(anchor.window === panel)
    let surface = PlatformDialogSurface()
    let queue = DialogQueue(surface: surface)
    var lifecycle = 0
    defer { surface.withdraw(); other.orderOut(nil) }
    let reply = await queue.ask(Dialog.confirm("No fallback", verb: "Continue") {}, in: anchor,
      shown: { lifecycle += 1 }, didDismiss: { lifecycle += 1 })
    #expect(reply == nil && lifecycle == 0)
    #expect(other.attachedSheet == nil)
  }

  @Test("Non-owner readers cannot replace the terminal owner's window or region")
  func nonOwnerReader() {
    let ownerWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let anchor = DialogAnchor()
    anchor.coverItsView()
    let owner = DialogAnchorReader.Reader()
    owner.anchor = anchor
    owner.claimsView = true
    ownerWindow.contentView = owner
    owner.claim()
    let observer = DialogAnchorReader.Reader()
    observer.anchor = anchor
    observer.claimsView = false
    otherWindow.contentView = observer
    observer.claim()
    #expect(anchor.window === ownerWindow)
    #expect(anchor.view === owner)
    otherWindow.contentView = nil
    #expect(anchor.window === ownerWindow && anchor.view === owner)
  }

  @Test("Withdrawing a native sheet reports gone only after it is detached and invisible")
  func nativeWithdrawal() async throws {
    let panel = HostPanel(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 300),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.orderFrontRegardless()
    let anchor = DialogAnchor()
    anchor.window = panel
    let surface = PlatformDialogSurface()
    var sheet: NSWindow?
    var gone = 0
    defer { surface.withdraw(); panel.orderOut(nil) }
    let shown = surface.show(Dialog.confirm("Preview withdrawal", verb: "Continue") {}, in: anchor,
      answer: { _, _ in Issue.record("withdrawal must not answer") }, gone: {
        gone += 1
        #expect(sheet?.isVisible == false, "gone must not release a host still displaying its sheet")
        #expect(sheet?.sheetParent == nil)
      })
    #expect(shown)
    try await settle { panel.attachedSheet?.isVisible == true }
    sheet = panel.attachedSheet
    surface.withdraw()
    try await settle { gone == 1 }
    surface.withdraw()
    #expect(gone == 1)
  }

  @Test("A second native question waits for the first surface to be gone", arguments: [false, true])
  func nativeQueueBoundary(withdraw: Bool) async throws {
    let panel = HostPanel(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 300),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.orderFrontRegardless()
    let anchor = DialogAnchor(window: panel)
    let surface = PlatformDialogSurface()
    let queue = DialogQueue(surface: surface)
    var firstSheet: NSWindow?
    var firstGone = 0
    var secondShown = 0
    var secondGone = 0
    var events: [String] = []
    let first = Task {
      await queue.ask(Dialog.confirm("First preview", verb: "Continue") {
        events.append("answered")
        #expect(secondShown == 0)
      }, in: anchor, didDismiss: {
        #expect(firstSheet?.isVisible == false && firstSheet?.sheetParent == nil)
        #expect(secondShown == 0)
        firstGone += 1
        events.append("first gone")
      })
    }
    defer { first.cancel(); surface.withdraw(); panel.orderOut(nil) }
    try await settle { panel.attachedSheet?.isVisible == true }
    firstSheet = panel.attachedSheet
    let second = Task {
      await queue.ask(Dialog.confirm("Second preview", verb: "Continue") {}, in: anchor, shown: {
        #expect(firstGone == 1)
        #expect(firstSheet?.isVisible == false && firstSheet?.sheetParent == nil)
        secondShown += 1
        events.append("second shown")
      }, didDismiss: { secondGone += 1 })
    }
    defer { second.cancel() }
    await Task.yield()
    #expect(secondShown == 0)
    if withdraw {
      first.cancel()
      #expect(await first.value == nil)
    } else {
      let sheet = try #require(firstSheet)
      let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
      #expect(surface.route(key) == nil)
      #expect(await first.value?.isAffirmative == true)
    }
    try await settle { secondShown == 1 }
    #expect(events == (withdraw ? ["first gone", "second shown"] : ["answered", "first gone", "second shown"]))
    second.cancel()
    #expect(await second.value == nil)
    try await settle { secondGone == 1 }
    #expect(firstGone == 1 && secondShown == 1)
  }

  @Test("Withdrawal before deferred region presentation does not wait for a native callback")
  func withdrawBeforePresentation() async throws {
    let panel = HostPanel(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 300),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.orderFrontRegardless()
    let anchor = DialogAnchor(window: panel)
    anchor.coverItsView()
    let surface = PlatformDialogSurface()
    var gone = 0
    defer { surface.withdraw(); panel.orderOut(nil) }
    let shown = surface.show(Dialog.confirm("Deferred preview", verb: "Continue") {}, in: anchor,
      answer: { _, _ in Issue.record("withdrawn before presentation") }, gone: { gone += 1 })
    #expect(shown)
    surface.withdraw()
    surface.withdraw()
    try await settle { gone == 1 }
    #expect(panel.attachedSheet == nil && panel.childWindows?.isEmpty != false)
  }
}
#endif
