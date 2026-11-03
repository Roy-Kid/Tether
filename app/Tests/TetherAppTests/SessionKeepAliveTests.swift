import Testing

@testable import TetherApp

@Suite("Session keep-alive")
struct SessionKeepAliveTests {
  @Test("a live session is held only while the scene is not in front")
  func holdsWhileAway() {
    #expect(!SessionKeepAlive.shouldHold(active: true, liveSessions: 2))
    #expect(SessionKeepAlive.shouldHold(active: false, liveSessions: 1))
    #expect(!SessionKeepAlive.shouldHold(active: false, liveSessions: 0))
    #expect(!SessionKeepAlive.shouldHold(active: true, liveSessions: 0))
  }
}
