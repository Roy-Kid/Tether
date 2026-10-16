import Foundation
import Testing
@testable import TetherApp
import struct TetherApp.Host

@MainActor
@Suite("Touch workspace")
struct TouchWorkspaceTests {
  private let known = KnownHosts(location: URL(fileURLWithPath: "/dev/null"))

  private func tab(_ name: String, host: Host = .local) -> SessionTab {
    SessionTab(preview: host, known: known, name: name, live: false)
  }

  private func host(_ label: String) -> Host {
    var host = Host.blank()
    host.label = label
    host.hostname = "\(label).example"
    return host
  }

  @Test("the touch Commands menu is short sections, without the palettes or what the screen shows")
  func commandSections() {
    let phone = TouchCommands.sections(wide: false)
    let pad = TouchCommands.sections(wide: true)
    for sections in [phone, pad] {
      #expect(sections.allSatisfy { !$0.isEmpty && $0.count <= 4 })
      let all = sections.flatMap { $0 }
      #expect(Set(all).count == all.count)
      for missing: WorkspaceAction in [
        .commandMenu, .quickSwitch, .previousTab, .nextTab, .previousTerminal, .nextTerminal,
        .closeTab, .closeTerminal, .changeHost, .newTerminal, .inspector, .zen, .toggleTabBar,
      ] {
        #expect(!all.contains(missing))
      }
      #expect(all.allSatisfy { WorkspaceAction.available.contains($0) })
    }
    #expect(phone.flatMap { $0 }.allSatisfy { !$0.needsWidth })
    #expect(pad.flatMap { $0 }.contains(.splitRight))
    #expect(pad.last == [.splitRight, .splitDown, .joinGroups])
  }

  @Test("a window without room for a second column cannot open one")
  func narrowWindow() {
    let tabs = TabSet()
    tabs.adopt(tab("shell"))
    #expect(tabs.canPerform(.inspector))
    #expect(tabs.canPerform(.splitRight))
    tabs.wide = false
    #expect(!tabs.canPerform(.inspector))
    #expect(!tabs.canPerform(.splitRight))
    #expect(!tabs.canPerform(.splitDown))
    tabs.perform(.splitRight)
    #expect(tabs.intent == nil)
    #expect(tabs.canPerform(.renameTerminal))
  }

  @Test("the title menu lists every terminal by host, marks the one in front, and switches")
  func terminalChoices() {
    let tabs = TabSet()
    let lab = host("lab"), build = host("build")
    let one = tab("Terminal 1", host: lab), two = tab("Terminal 2", host: lab), other = tab("Terminal 1", host: build)
    tabs.adopt(one)
    tabs.adopt(other)
    tabs.adopt(two)
    let groups = tabs.terminalChoices
    #expect(groups.map(\.title) == ["lab", "build"])
    #expect(groups[0].choices.map(\.id) == [one.id, two.id])
    #expect(groups[1].choices.map(\.id) == [other.id])
    #expect(groups.flatMap(\.choices).filter(\.current).map(\.id) == [two.id])
    #expect(groups[0].choices[0].title.hasPrefix("Terminal 1"))

    tabs.select(other.id)
    #expect(tabs.terminalChoices.flatMap(\.choices).filter(\.current).map(\.id) == [other.id])
    #expect(tabs.currentHost?.id == build.id)
  }

  @Test("plugin workspaces are listed under their host, or on their own")
  func workspaceChoices() {
    let tabs = TabSet()
    let lab = host("lab")
    tabs.adopt(tab("Terminal 1", host: lab))
    let attached = StubWorkspace(title: "Logs"), loose = StubWorkspace(title: "Notes")
    tabs.openExtension(attached, pluginID: "logs", hostID: lab.id)
    tabs.openExtension(loose, pluginID: "notes", hostID: nil)
    let groups = tabs.terminalChoices
    #expect(groups.count == 2)
    #expect(groups[0].choices.map(\.title).last == "Logs")
    #expect(groups[1].id == nil)
    #expect(groups[1].choices.map(\.title) == ["Notes"])
    #expect(groups[1].choices[0].current)
  }
}
