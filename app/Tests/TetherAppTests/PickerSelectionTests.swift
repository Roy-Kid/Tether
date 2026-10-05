import Testing
@testable import TetherApp

@Suite("Picker keyboard navigation")
struct PickerSelectionTests {
  @Test("paging and endpoints stay within the currently available results")
  func pages() {
    let ids = Array(0..<20)
    var selection = PickerSelection<Int>()
    selection.reconcile(ids)
    selection.navigate(.pageDown, pageSize: 6, in: ids)
    #expect(selection.id == 6)
    selection.navigate(.last, in: ids)
    #expect(selection.id == 19)
    selection.navigate(.pageDown, pageSize: 6, in: ids)
    #expect(selection.id == 19)
    selection.navigate(.pageUp, pageSize: 6, in: ids)
    #expect(selection.id == 13)
    selection.navigate(.first, in: ids)
    #expect(selection.id == 0)
    selection.navigate(.last, in: [])
    #expect(selection.id == nil)
  }
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
