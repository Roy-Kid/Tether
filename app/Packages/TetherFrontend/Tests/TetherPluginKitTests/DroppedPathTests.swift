import Foundation
import Testing

@testable import TetherPluginKit

@Test("a dropped path is the text it was given, including a space")
func droppedPathRoundTrips() throws {
  let text = "/home/ada/my shot.png"
  let decoded = try #require(DroppedPath.text(in: DroppedPath.data(for: text)))
  #expect(decoded == text)
  #expect(DroppedPath.text(in: Data()) == nil)
}
