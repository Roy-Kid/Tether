import Foundation
import SwiftUI
import Testing
import Tether

@testable import TetherPluginKit

@MainActor
private final class ExamplePlugin: TetherPlugin {
  let metadata = PluginMetadata(
    id: "test.example", name: "Example", symbol: "star", summary: "Test extension")
  var starts = 0
  var stops = 0
  func activate() { starts += 1 }
  func deactivate() { stops += 1 }
  func launch(in context: PluginContext) { context.openWorkspace(ExampleWorkspace()) }
}
@MainActor
private final class ExampleWorkspace: PluginWorkspace {
  let id = UUID()
  let title = "Example"
  let subtitle = "Independent extension"
  let symbol = "star"
  var invoked = false
  var closed = false
  var commands: [PluginCommand] {
    [
      PluginCommand(id: "example.action", title: "Run", symbol: "play") { [weak self] in
        self?.invoked = true
      }
    ]
  }
  func content() -> AnyView { AnyView(Text(title)) }
  func inspector() -> AnyView { AnyView(Text(subtitle)) }
  func close() { closed = true }
}

@Test @MainActor
func disableReleasesWorkspacesAndPersistsWithoutChangingHost() {
  let name = "TetherTests.\(UUID())"
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let registry = PluginRegistry(defaults: defaults)
  let plugin = ExamplePlugin()
  let workspace = ExampleWorkspace()
  registry.register(plugin)
  #expect(plugin.starts == 1)
  workspace.commands[0].action()
  #expect(workspace.invoked)
  registry.onDisable = { id in if id == plugin.metadata.id { workspace.close() } }
  registry.setEnabled(false, id: plugin.metadata.id)
  #expect(workspace.closed)
  #expect(plugin.stops == 1)
  registry.setEnabled(false, id: plugin.metadata.id)
  #expect(plugin.stops == 1)
  let restored = PluginRegistry(defaults: defaults)
  let other = ExamplePlugin()
  restored.register(other)
  #expect(other.starts == 0)
  restored.setEnabled(true, id: other.metadata.id)
  #expect(other.starts == 1)
}

@Test
func preferenceNamespacesDoNotOverlap() {
  let name = "TetherTests.\(UUID())"
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let first = PluginPreferences(pluginID: "first", defaults: defaults)
  let second = PluginPreferences(pluginID: "second", defaults: defaults)
  first.set("A", for: "mode")
  second.set("B", for: "mode")
  #expect(first.string(for: "mode") == "A")
  #expect(second.string(for: "mode") == "B")
}

@MainActor
private final class ExampleTabPlugin: TabPlugin {
  let metadata = PluginMetadata(
    id: "test.tab", name: "Tab", symbol: "star", summary: "Test tab extension")
  let accessory = TabAccessory(symbol: "star", name: "tab things")
  var attached: [UUID] = []
  func attach(to tab: TabContext) -> any TabAttachment {
    attached.append(tab.id)
    return ExampleAttachment()
  }
}
@MainActor
private final class ExampleAttachment: TabAttachment {
  let isShowing = false
  let subtitle = ""
  let isDisconnected = false
  let closeNote: String? = nil
  var commands: [PluginCommand] { [] }
  func content() -> AnyView { AnyView(EmptyView()) }
  func inspector() -> AnyView { AnyView(EmptyView()) }
  func accessoryContent() -> AnyView { AnyView(EmptyView()) }
  func connectionChanged(_ connection: RemoteConnection) {}
  func close() {}
}

/// A tab plugin is reached through its accessory. Launching it the way a
/// workspace plugin is launched must open nothing, or the host would get a
/// workspace tab it never asked for.
@Test @MainActor
func aTabPluginOpensNoWorkspace() {
  let plugin = ExampleTabPlugin()
  var opened = 0
  plugin.launch(
    in: PluginContext(
      connection: nil, hostLabel: "", hostID: UUID(),
      openWorkspace: { _ in opened += 1 }, reconnect: { throw CancellationError() }))
  #expect(opened == 0)
  #expect(plugin.attached.isEmpty)
  let registry = PluginRegistry(defaults: UserDefaults(suiteName: "TetherTests.\(UUID())")!)
  registry.register(plugin)
  #expect(registry.plugins.first is any TabPlugin, "the host finds tab plugins by conformance")
}

/// Most accessories are something to choose from, and a popover is where a
/// choice is made. One that is worth keeping open beside the terminal says
/// so, and the host puts it in the inspector instead.
@Test
func anAccessoryOpensAsAPopoverUnlessItSaysOtherwise() {
  #expect(TabAccessory(symbol: "star", name: "things").placement == .popover)
  #expect(
    TabAccessory(symbol: "folder", name: "Files", placement: .inspector).placement == .inspector)
}

/// Dropping files on a tab is offered to what is attached to it. An
/// attachment that says nothing about drops has not accepted one.
@Test @MainActor
func anAttachmentDeclinesDroppedFilesByDefault() {
  let attachment = ExampleAttachment()
  #expect(!attachment.receive(files: [URL(fileURLWithPath: "/tmp/a.png")]))
}

/// Text a plugin wants typed at the prompt goes through the host, which owns
/// the terminal. A context built without it types nothing.
@Test @MainActor
func aTabTypesThroughTheHost() {
  var typed: [String] = []
  let plugin = PluginContext(
    connection: nil, hostLabel: "", hostID: UUID(),
    openWorkspace: { _ in }, reconnect: { throw CancellationError() })
  let quiet = TabContext(
    id: UUID(), plugin: plugin, focus: {}, dismissAccessory: {}, present: { _ in },
    dismissSheet: {})
  quiet.insertText("ignored")
  let typing = TabContext(
    id: UUID(), plugin: plugin, focus: {}, dismissAccessory: {}, present: { _ in },
    dismissSheet: {}, insertText: { typed.append($0) })
  typing.insertText("'/tmp/a b.png' ")
  #expect(typed == ["'/tmp/a b.png' "])
}

/// Pointing at a path in the terminal is offered to what is attached to the
/// tab. An attachment that says nothing about links offers nothing.
@Test @MainActor
func anAttachmentOffersNothingForALinkByDefault() {
  let link = TerminalLink(
    text: "plot.png", kind: .path(path: "plot.png", line: nil, column: nil),
    spans: [LinkSpan(row: 0, start: 0, end: 8)])
  #expect(ExampleAttachment().actions(for: PointedLink(link: link, directory: { nil })) == nil)
}

/// A plugin resolving a relative path asks the tab where its shell is, and
/// can bring its own accessory up to show what it found.
@Test @MainActor
func aTabSaysWhereItsShellIsAndCanShowItsAccessory() {
  var shown = 0
  let plugin = PluginContext(
    connection: nil, hostLabel: "", hostID: UUID(),
    openWorkspace: { _ in }, reconnect: { throw CancellationError() })
  let quiet = TabContext(
    id: UUID(), plugin: plugin, focus: {}, dismissAccessory: {}, present: { _ in },
    dismissSheet: {})
  #expect(quiet.workingDirectory() == nil)
  let told = TabContext(
    id: UUID(), plugin: plugin, focus: {}, dismissAccessory: {}, present: { _ in },
    dismissSheet: {}, workingDirectory: { "/home/ada/runs" }, showAccessory: { shown += 1 })
  #expect(told.workingDirectory() == "/home/ada/runs")
  told.showAccessory()
  #expect(shown == 1)
}

/// Two plugins' offers for one link read as one menu, and the link is there
/// if either finds it.
@Test @MainActor
func offersForALinkCombine() async {
  var opened: [String] = []
  let first = LinkActions(
    open: { opened.append("first") },
    commands: [PluginCommand(id: "a", title: "A", symbol: "a.circle") {}],
    exists: { false })
  let second = LinkActions(
    open: { opened.append("second") },
    commands: [PluginCommand(id: "b", title: "B", symbol: "b.circle") {}],
    exists: { true })
  let combined = LinkActions.combining([first, second])!
  combined.open?()
  #expect(opened == ["first"])
  #expect(combined.commands.map(\.title) == ["A", "B"])
  #expect(await combined.exists?() == true)
  #expect(LinkActions.combining([]) == nil)
}
