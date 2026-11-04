import Testing
@testable import TetherApp

@Suite("Picker keyboard navigation")
struct PickerSelectionTests {
  @Test("filtering preserves identity rather than the old row index")
  func filtering() {
    var selection = PickerSelection<String>()
    selection.reconcile(["alpha", "beta", "gamma"])
    selection.move(forward: true, in: ["alpha", "beta", "gamma"])
    selection.reconcile(["beta", "gamma"])
    #expect(selection.id == "beta")
    selection.reconcile(["gamma"])
    #expect(selection.id == "gamma")
  }

}
