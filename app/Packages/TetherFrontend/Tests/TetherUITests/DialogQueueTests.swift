import Testing

@testable import TetherUI

/// A surface that shows nothing, and answers when the test says so.
@MainActor
private final class RecordingSurface: DialogSurface {
  private(set) var shown: [String] = []
  private(set) var withdrawn: [String] = []
  var available = true
  var delaysWithdrawal = false
  private var answer: ((Int, [String]) -> Void)?
  private var gone: (() -> Void)?
  private var current: String?

  func show(
    _ dialog: Dialog, in anchor: DialogAnchor?,
    answer: @escaping (Int, [String]) -> Void, gone: @escaping () -> Void
  ) -> Bool {
    guard available else { return false }
    #expect(current == nil, "a dialog was shown over another one")
    shown.append(dialog.title)
    current = dialog.title
    self.answer = answer
    self.gone = gone
    return true
  }

  func withdraw() {
    if let current { withdrawn.append(current) }
    if !delaysWithdrawal { finishDismissal() }
  }

  /// A person taps an action; the dialog then finishes animating away.
  func tap(_ action: Int, values: [String] = []) {
    answer?(action, values)
    finishDismissal()
  }

  /// A person taps, but the dismissal has not finished yet.
  func tapWithoutDismissing(_ action: Int, values: [String] = []) {
    answer?(action, values)
    answer = nil
  }

  func finishDismissal() {
    let gone = self.gone
    answer = nil
    self.gone = nil
    current = nil
    gone?()
  }
}

/// Lets queued main-actor work run until `condition` holds.
@MainActor
private func settle(until condition: () -> Bool = { false }) async {
  for _ in 0..<50 where !condition() { await Task.yield() }
}

@MainActor
private func dialog(_ title: String, fields: [Dialog.Field] = [], perform: @escaping @MainActor ([String]) -> Void = { _ in }) -> Dialog {
  Dialog(title: title, fields: fields, actions: [.cancel(), Dialog.Action("Continue", perform: perform)])
}

/// The queue every dialog goes through. What it promises is the whole reason
/// there is one path: a dialog never lands on another one, a question that
/// is withdrawn leaves the screen, and whoever asked hears back exactly once.
@MainActor
@Suite("Dialog queue")
struct DialogQueueTests {
  @Test("one at a time, in the order asked")
  func oneAtATime() async {
    let surface = RecordingSurface()
    let queue = DialogQueue(surface: surface)

    let first = Task { await queue.ask(dialog("Unrecognised host")) }
    await settle { surface.shown.count == 1 }
    let second = Task {
      await queue.ask(dialog("Verification code", fields: [Dialog.Field("Verification code", kind: .code)]))
    }
    await settle()
    #expect(surface.shown == ["Unrecognised host"], "the second waits for the first to be gone")

    surface.tapWithoutDismissing(1)
    await settle()
    #expect(surface.shown == ["Unrecognised host"], "not while the first is still animating away")

    surface.finishDismissal()
    await settle { surface.shown.count == 2 }
    #expect(surface.shown == ["Unrecognised host", "Verification code"])
    surface.tap(1, values: ["424242"])

    #expect(await first.value == DialogReply(action: 1, role: .confirm, values: []))
    #expect(await second.value == DialogReply(action: 1, role: .confirm, values: ["424242"]))
  }

  @Test("a withdrawn question leaves the screen and is not answered")
  func withdrawal() async {
    let surface = RecordingSurface()
    let queue = DialogQueue(surface: surface)
    var ran = false

    let asking = Task { await queue.ask(dialog("Verification code") { _ in ran = true }) }
    await settle { !surface.shown.isEmpty }
    #expect(surface.shown == ["Verification code"])

    asking.cancel()
    #expect(await asking.value == nil)
    #expect(surface.withdrawn == ["Verification code"])
    #expect(!ran)
  }

  @Test("a question withdrawn before its turn is never shown")
  func withdrawnWhileWaiting() async {
    let surface = RecordingSurface()
    let queue = DialogQueue(surface: surface)

    let first = Task { await queue.ask(dialog("Approve")) }
    await settle { !surface.shown.isEmpty }
    let second = Task { await queue.ask(dialog("Close Terminal 1?")) }
    await settle()
    second.cancel()
    #expect(await second.value == nil)

    surface.tap(1)
    _ = await first.value
    await settle()
    #expect(surface.shown == ["Approve"])
  }

  /// A Mac sheet whose window closes under it, or any other ending the
  /// platform chose: whoever asked hears nil, and the next dialog gets its
  /// turn, rather than both waiting on a dialog that is nowhere.
  @Test("gone without an answer still ends the question")
  func goneUnanswered() async {
    let surface = RecordingSurface()
    let queue = DialogQueue(surface: surface)

    let first = Task { await queue.ask(dialog("Approve")) }
    await settle { !surface.shown.isEmpty }
    let second = Task { await queue.ask(dialog("Verification code")) }
    await settle()
    surface.finishDismissal()
    #expect(await first.value == nil)
    await settle { surface.shown.count == 2 }
    #expect(surface.shown == ["Approve", "Verification code"])
    surface.tap(1)
    #expect(await second.value?.role == .confirm)
  }

  @Test("shown means on screen, not asked")
  func shownWhenOnScreen() async {
    let surface = RecordingSurface()
    let queue = DialogQueue(surface: surface)
    var shown: [String] = []

    let first = Task { await queue.ask(dialog("Approve"), shown: { shown.append("Approve") }) }
    await settle { !surface.shown.isEmpty }
    let second = Task { await queue.ask(dialog("Verification code"), shown: { shown.append("code") }) }
    await settle()
    #expect(shown == ["Approve"], "waiting behind another dialog is not being asked")

    surface.tap(1)
    await settle { shown.count == 2 }
    #expect(shown == ["Approve", "code"])
    surface.tap(0)
    _ = await (first.value, second.value)
  }

  @Test("destructive actions require an explicit Return opt-in")
  func defaultAction() {
    let delete = Dialog.confirm("Delete 3 items?", verb: "Delete", role: .destructive) {}
    #expect(delete.defaultAction == nil)
    #expect(delete.cancelAction == 0)

    let trust = Dialog.confirm("Unrecognised host", verb: "Trust") {}
    #expect(trust.defaultAction == 1)

    let close = Dialog.confirm("Close Terminal 1?", verb: "Close", role: .destructive,
      shortcuts: [.enter, .command("w")]) {}
    #expect(close.defaultAction == 1)
    #expect(close.cancelAction == 0)
  }

  @Test("Answer completion retains the presentation lease until gone, then releases before the next shown")
  func dismissalAfterAnswer() async {
    let surface = RecordingSurface()
    let queue = DialogQueue(surface: surface)
    var events: [String] = []
    let first = Task {
      let reply = await queue.ask(dialog("First") { _ in events.append("performed") },
        shown: { events.append("shown") }, didDismiss: { events.append("dismissed") })
      events.append("returned")
      return reply
    }
    await settle { surface.shown.count == 1 }
    let second = Task {
      await queue.ask(dialog("Second"), shown: { events.append("next shown") })
    }
    await settle()
    surface.tapWithoutDismissing(1)
    #expect(await first.value?.isAffirmative == true)
    #expect(events == ["shown", "performed", "returned"])
    surface.finishDismissal()
    await settle { surface.shown.count == 2 }
    #expect(events == ["shown", "performed", "returned", "dismissed", "next shown"])
    surface.finishDismissal()
    surface.finishDismissal()
    #expect(await second.value == nil)
    #expect(events.filter { $0 == "dismissed" }.count == 1)
  }

  @Test("Cancellation completion does not release a visible surface's presentation lease")
  func dismissalAfterWithdrawal() async {
    let surface = RecordingSurface()
    surface.delaysWithdrawal = true
    let queue = DialogQueue(surface: surface)
    var shown = 0
    var dismissed = 0
    let task = Task {
      await queue.ask(dialog("First"), shown: { shown += 1 }, didDismiss: { dismissed += 1 })
    }
    await settle { shown == 1 }
    task.cancel()
    #expect(await task.value == nil)
    #expect(dismissed == 0)
    surface.finishDismissal()
    surface.finishDismissal()
    #expect(shown == 1 && dismissed == 1)
  }

  @Test("Unpresented questions never acquire or release a presentation lease")
  func noUnpresentedLifecycle() async {
    let surface = RecordingSurface()
    let queue = DialogQueue(surface: surface)
    var shown = 0
    var dismissed = 0
    let first = Task { await queue.ask(dialog("First")) }
    await settle { surface.shown.count == 1 }
    let waiting = Task {
      await queue.ask(dialog("Waiting"), shown: { shown += 1 }, didDismiss: { dismissed += 1 })
    }
    await settle()
    waiting.cancel()
    #expect(await waiting.value == nil)
    surface.finishDismissal()
    #expect(await first.value == nil)
    surface.available = false
    let missingHost = await queue.ask(dialog("Nowhere"), shown: { shown += 1 }, didDismiss: { dismissed += 1 })
    #expect(missingHost == nil)
    #expect(shown == 0 && dismissed == 0)
  }

  @Test("Unanswered disappearance ends the owner lifecycle exactly once")
  func unansweredLifecycle() async {
    let surface = RecordingSurface()
    let queue = DialogQueue(surface: surface)
    var shown = 0
    var dismissed = 0
    let task = Task {
      await queue.ask(dialog("First"), shown: { shown += 1 }, didDismiss: { dismissed += 1 })
    }
    await settle { shown == 1 }
    surface.finishDismissal()
    surface.finishDismissal()
    #expect(await task.value == nil)
    #expect(shown == 1 && dismissed == 1)
  }

}
