#if os(iOS)
import Testing
import UIKit

@testable import TetherUI

@MainActor
@Suite("Phone key bar")
struct KeyBarTests {
  @Test("hide keyboard stays at the right edge while the row of keys scrolls")
  func hidePinned() throws {
    let bar = KeyBar(onKey: { _ in }, onModifier: { _ in }, onDismiss: {})
    // Narrower than the row, so the keys have to scroll.
    bar.frame = CGRect(x: 0, y: 0, width: 240, height: bar.fittingHeight)
    bar.layoutIfNeeded()
    let scroll = try #require(bar.subviews.compactMap { $0 as? UIScrollView }.first)
    let hide = try #require(bar.subviews.compactMap { $0 as? UIButton }.first)
    #expect(hide.accessibilityLabel == "Hide keyboard")
    #expect(!hide.isDescendant(of: scroll), "the hide key is not part of the scrolling row")
    #expect(scroll.contentSize.width > scroll.bounds.width, "the row scrolls at this width")
    #expect(hide.frame.minX >= scroll.frame.maxX, "the row ends before the hide key")
    #expect(abs(bar.bounds.width - hide.frame.maxX) < 20, "the hide key sits at the right edge")

    let before = bar.convert(hide.bounds, from: hide)
    scroll.setContentOffset(CGPoint(x: scroll.contentSize.width - scroll.bounds.width, y: 0), animated: false)
    bar.layoutIfNeeded()
    #expect(bar.convert(hide.bounds, from: hide) == before, "scrolling the row leaves it where it is")
  }
}
#endif
