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

  @Test("unavailable commands are skipped and navigation stops at the ends")
  func availableCommands() {
    let items = [
      CommandItem(id: "disabled", title: "", detail: "", enabled: false, run: {}),
      CommandItem(id: "first", title: "", detail: "", enabled: true, run: {}),
      CommandItem(id: "middle", title: "", detail: "", enabled: false, run: {}),
      CommandItem(id: "last", title: "", detail: "", enabled: true, run: {}),
    ]
    let available = items.filter(\.enabled).map(\.id)
    var selection = PickerSelection<String>()
    selection.reconcile(available)
    #expect(selection.id == "first")
    selection.move(forward: false, in: available)
    #expect(selection.id == "first")
    selection.move(forward: true, in: available)
    #expect(selection.id == "last")
    selection.move(forward: true, in: available)
    #expect(selection.id == "last")
  }

  @Test("empty results clear the choice and recovering results select the first")
  func emptyResults() {
    var selection = PickerSelection<String>()
    selection.reconcile(["host"])
    selection.reconcile([])
    #expect(selection.id == nil)
    selection.move(forward: true, in: [])
    #expect(selection.id == nil)
    selection.reconcile(["other"])
    #expect(selection.id == "other")
  }
}
