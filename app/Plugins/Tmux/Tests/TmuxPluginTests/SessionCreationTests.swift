import Testing
import Tether
@testable import TmuxPlugin

@MainActor
@Suite("Session creation recovery")
struct SessionCreationTests {
  private enum Failure: Error { case unavailable }

  @Test("retry attaches the created session without creating another")
  func attachmentRetry() async throws {
    let attempt = SessionCreation()
    let session = TmuxSessionInfo(id: "$17", name: "work", attached: false, windows: [])
    var creations = 0
    do {
      _ = try await attempt.perform(name: "work", create: { _ in
        creations += 1
        return session
      }, attach: { _ in throw Failure.unavailable })
      Issue.record("An attachment failure must remain a failure")
    } catch Failure.unavailable {}
    let attached = try await attempt.perform(name: "work", create: { _ in
      creations += 1
      return session
    }, attach: { #expect($0.id == "$17") })
    #expect(creations == 1)
    #expect(attached.id == "$17")
  }

  @Test("a creation failure can retry and a changed name starts a new attempt")
  func creationRetry() async throws {
    let attempt = SessionCreation()
    do {
      _ = try await attempt.perform(name: "work", create: { _ in throw Failure.unavailable },
        attach: { _ in Issue.record("No session exists to attach") })
      Issue.record("A creation failure must remain a failure")
    } catch Failure.unavailable {}
    let created = try await attempt.perform(name: "work", create: {
      TmuxSessionInfo(id: "$18", name: $0, attached: false, windows: [])
    }, attach: { _ in })
    #expect(created.name == "work")
    let next = try await attempt.perform(name: "other", create: {
      TmuxSessionInfo(id: "$19", name: $0, attached: false, windows: [])
    }, attach: { _ in })
    #expect(next.name == "other")
  }
}
