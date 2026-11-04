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

}
