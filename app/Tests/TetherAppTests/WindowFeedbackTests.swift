import Foundation
import Testing
@testable import TetherApp

/// Intentionally ignores cancellation so tests can deliver a stale timer.
@MainActor
private final class FeedbackSleeper {
  var durations: [Duration] = []
  var continuations: [CheckedContinuation<Void, Never>?] = []
  var resumed = 0
  var cancelled = 0
  private var finished = false

  func sleep(_ duration: Duration) async {
    guard !finished else { return }
    durations.append(duration)
    await withCheckedContinuation { continuations.append($0) }
    resumed += 1
    if Task.isCancelled { cancelled += 1 }
  }

  func waitForTimers(_ count: Int) async {
    for _ in 0..<100 where continuations.count < count { await Task.yield() }
    #expect(continuations.count == count)
  }

  func wake(_ index: Int) async {
    let expected = resumed + 1
    continuations[index]?.resume()
    continuations[index] = nil
    for _ in 0..<100 where resumed < expected { await Task.yield() }
    #expect(resumed == expected)
  }

  func finish() {
    finished = true
    for index in continuations.indices {
      continuations[index]?.resume()
      continuations[index] = nil
    }
  }
}

@MainActor
@Suite("Window feedback")
struct WindowFeedbackTests {
  @Test("a window has one replacement slot and a stale cancelled expiry cannot clear its successor")
  func replacementAndStaleExpiry() async throws {
    let clock = FeedbackSleeper()
    let feedback = WindowFeedback(sleep: { await clock.sleep($0) })
    defer { feedback.dismissAll(); clock.finish() }
    let host = UUID()
    #expect(feedback.message(for: host) == nil)
    feedback.show(title: "Always on Top", symbol: "pin.fill",
      accessibilityLabel: "Always on Top: On", in: host)
    let first = try #require(feedback.message(for: host))
    #expect(!first.isStruckThrough)
    #expect(first.accessibilityLabel == "Always on Top: On")
    await clock.waitForTimers(1)
    feedback.show(title: "Always on Top", symbol: "pin.slash", isStruckThrough: true,
      accessibilityLabel: "Always on Top: Off", in: host)
    let replacement = try #require(feedback.message(for: host))
    #expect(replacement.id != first.id)
    #expect(replacement.title == "Always on Top")
    #expect(replacement.title == first.title)
    #expect(replacement.symbol == "pin.slash")
    #expect(replacement.isStruckThrough)
    #expect(replacement.accessibilityLabel == "Always on Top: Off")
    await clock.waitForTimers(2)
    #expect(clock.durations == [.seconds(2), .seconds(2)])
    await clock.wake(0)
    #expect(clock.cancelled == 1)
    #expect(feedback.message(for: host) == replacement)
    await clock.wake(1)
    #expect(feedback.message(for: host) == nil)
  }

  @Test("windows expire independently without moving or replaying another window's message")
  func windowIsolation() async throws {
    let clock = FeedbackSleeper()
    let feedback = WindowFeedback(sleep: { await clock.sleep($0) })
    defer { feedback.dismissAll(); clock.finish() }
    let first = UUID(), second = UUID()
    feedback.show(title: "First", symbol: "pin.fill", in: first)
    let firstMessage = try #require(feedback.message(for: first))
    #expect(!firstMessage.isStruckThrough)
    #expect(firstMessage.accessibilityLabel == firstMessage.title)
    await clock.waitForTimers(1)
    #expect(feedback.message(for: second) == nil)
    feedback.show(title: "Second", symbol: "pin.slash", in: second)
    let secondMessage = try #require(feedback.message(for: second))
    #expect(!secondMessage.isStruckThrough)
    #expect(secondMessage.accessibilityLabel == "Second")
    await clock.waitForTimers(2)
    await clock.wake(0)
    #expect(feedback.message(for: first) == nil)
    #expect(feedback.message(for: second) == secondMessage)
    await clock.wake(1)
    #expect(feedback.message(for: second) == nil)
    #expect(feedback.message(for: first) == nil)
  }

  @Test("clearing one or all windows cancels expiry and late timers cannot revive cleared feedback")
  func clearCancelsTimers() async {
    let clock = FeedbackSleeper()
    let feedback = WindowFeedback(sleep: { await clock.sleep($0) })
    defer { feedback.dismissAll(); clock.finish() }
    let first = UUID(), second = UUID()
    feedback.show(title: "First", symbol: "pin.fill", in: first)
    feedback.show(title: "Second", symbol: "pin.fill", in: second)
    await clock.waitForTimers(2)
    feedback.dismiss(in: first)
    #expect(feedback.message(for: first) == nil)
    #expect(feedback.message(for: second) != nil)
    feedback.dismissAll()
    feedback.dismissAll()
    #expect(feedback.message(for: second) == nil)
    await clock.wake(0)
    await clock.wake(1)
    #expect(clock.cancelled == 2)
    #expect(feedback.message(for: first) == nil)
    #expect(feedback.message(for: second) == nil)
  }
}
