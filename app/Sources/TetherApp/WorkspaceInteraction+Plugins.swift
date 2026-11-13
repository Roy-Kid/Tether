import Foundation
import SwiftUI
import Tether
import TetherPluginKit
import TetherUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension WorkspaceInteraction {
  func commandItems(from hostID: UUID) -> [CommandItem] {
    let definitions = KeyBindingCatalog.commands(registry: registry, tabs: tabs)
    func detail(_ command: KeyBindingCommand) -> String {
      let shortcut = tabs.keyBindings.summary(for: command)
      return shortcut.isEmpty ? command.group : "\(command.group) · \(shortcut)"
    }
    var items = WorkspaceAction.available.filter { action in
      #if os(iOS)
      if [.splitLeft, .splitRight, .splitUp, .splitDown, .joinGroups].contains(action) { return false }
      #endif
      return (tabs.wide || !action.needsWidth) && (action.hostSlot.map { store.listed.indices.contains($0) } ?? true)
    }.map { action in
      let command = action.command
      let hostLabel = action.hostSlot.flatMap { store.listed[safe: $0]?.displayName }
      return CommandItem(id: command.id,
        title: hostLabel ?? (action == .toggleTabBar ? command.title : tabs.title(for: action)),
        detail: detail(command),
        enabled: [.closeTerminal, .closeTab].contains(action) ? tabs.selected != nil : tabs.canPerform(action)) {
        self.tabs.palette = nil
        _ = self.dispatch(action, from: hostID)
      }
    }
    for plugin in registry.plugins where registry.isEnabled(plugin.metadata.id) {
      let id = plugin.metadata.id
      if !plugin.isStatusBarOnly, let definition = definitions.first(where: { $0.id == KeyBindingCatalog.launchID(id) }) {
        let blocked = plugin is any TabPlugin ? tabs.current?.canOpen(id) != true
          : plugin.needsRemoteConnection && tabs.current?.connection == nil
        items.append(CommandItem(id: definition.id, title: definition.title, detail: detail(definition), enabled: !blocked) {
          self.tabs.palette = nil
          self.launch(plugin, from: hostID)
        })
      }
      let commands = tabs.extensions.first(where: { $0.id == tabs.selected && $0.pluginID == id })?.workspace.commands
        ?? tabs.current?.attachment(for: id)?.commands ?? []
      for command in commands {
        let commandID = KeyBindingCatalog.commandID(command.id, plugin: id)
        guard let definition = definitions.first(where: { $0.id == commandID }) else { continue }
        items.append(CommandItem(id: commandID, title: command.title, detail: detail(definition), enabled: true) {
          self.tabs.palette = nil
          _ = self.performOnWorkspace(command.action)
        })
      }
    }
    return items
  }

  func refreshPlugins() {
    tabs.accessories = registry.plugins.compactMap { plugin in
      guard let plugin = plugin as? any TabPlugin, registry.isEnabled(plugin.metadata.id) else { return nil }
      return PluginAccessory(id: plugin.metadata.id, title: plugin.metadata.name, accessory: plugin.accessory)
    }
    for tab in tabs.tabs where tab.isLive {
      for plugin in tabs.accessories { prepareAttachment(plugin.id, on: tab) }
    }
    if let open = tabs.accessory, let tab = tabs.tabs.first(where: { $0.id == open.tab }) {
      prepareAttachment(open.plugin, on: tab)
    }
    if let id = tabs.inspectorPlugin, let tab = tabs.current { prepareAttachment(id, on: tab) }
  }

  func prepareAttachment(_ pluginID: String, on tab: SessionTab) {
    if let attachment = tab.attachment(for: pluginID) {
      if let connection = tab.connection { attachment.connectionChanged(connection) }
      return
    }
    guard let plugin = registry.plugins.first(where: { $0.metadata.id == pluginID }) as? any TabPlugin,
      registry.isEnabled(pluginID) else { return }
    tab.attach(plugin.attach(to: tabContext(for: tab, plugin: plugin)), for: pluginID)
  }

  private func shellLabel(for tab: SessionTab?) -> String {
    if tab?.host.isLocal == true, let path = ProcessInfo.processInfo.environment["SHELL"], !path.isEmpty {
      return URL(fileURLWithPath: path).lastPathComponent
    }
    return "Shell"
  }

  private func pluginContext(for tab: SessionTab, pluginID: String, pluginName: String) -> PluginContext {
    PluginContext(connection: tab.connection, hostLabel: tab.host.label.isEmpty ? tab.host.hostname : tab.host.label,
      hostID: tab.host.id, shellLabel: shellLabel(for: tab), pluginID: pluginID, pluginName: pluginName,
      openWorkspace: { _ in }, reconnect: { [weak self, weak tab] in
        guard let self, let tab else { throw CancellationError() }
        return try await self.reconnect(host: tab.host)
      })
  }

  private func tabContext(for tab: SessionTab, plugin: any TetherPlugin) -> TabContext {
    let id = tab.id
    let pluginID = plugin.metadata.id
    return TabContext(id: id, plugin: pluginContext(for: tab, pluginID: pluginID, pluginName: plugin.metadata.name),
      terminalName: { [weak tab] in tab?.terminalName }, terminalHost: { [weak tab] in tab?.pluginTerminalIdentity?.host },
      focus: { [weak self] in self?.tabs.select(id) },
      dismissAccessory: { [weak self] in self?.tabs.dismissAccessory(pluginID, on: id) },
      present: { [weak self] view in
        _ = self?.performOnWorkspace { [weak self] in self?.tabs.sheet = PluginSheet(tab: id, plugin: pluginID, view: view) }
      },
      dismissSheet: { [weak self] in if self?.tabs.sheet?.tab == id { self?.tabs.sheet = nil } },
      insertText: { [weak tab] in tab?.send(.paste($0)) },
      runInTerminal: { [weak tab] line in
        tab?.send(.key(.text("e"), .init(control: true)))
        tab?.send(.key(.text("u"), .init(control: true)))
        tab?.send(.paste(line))
        tab?.send(.key(.enter))
      },
      workingDirectory: { [weak tab] in tab?.workingDirectory },
      resolveWorkingDirectory: { [weak self, weak tab] link in
        guard let self, let tab else { return nil }
        return await self.workingDirectory(for: link, on: tab)
      },
      showAccessory: { [weak self] in
        _ = self?.performOnWorkspace { [weak self] in self?.tabs.showAccessory(pluginID, on: id) }
      },
      linkActions: { [weak self, weak tab] pointed in
        guard let self, let tab else { return nil }
        return self.linkActions(for: pointed, on: tab)
      },
      shells: { [weak self] in
        guard let self, let host = self.tabs.tabs.first(where: { $0.id == id })?.host.id else { return [] }
        return self.tabs.hostShells(host, current: id)
      },
      openShell: { [weak self] in self?.tabs.select($0) },
      newShell: { [weak self] in
        guard let self, let page = self.tabs.workspace(containing: id) else { return }
        self.submit(.addTerminal(page.id))
      },
      renameShell: { [weak self] in self?.tabs.rename($0, to: $1) },
      scrollBy: { [weak tab] in tab?.scrollOwnHistory(by: $0) },
      reportWheel: { [weak tab] lines, column, row in
        guard let tab, lines != 0 else { return }
        let button: PointerButton = lines > 0 ? .wheelUp : .wheelDown
        for _ in 0..<WheelReports.count(lines) { tab.send(.pointer(button: button, phase: .press, column: column, row: row)) }
      }, mouseTracking: { [weak tab] in tab?.frame?.mouse ?? .off },
      terminalIndicator: { [weak self, weak tab] terminals in
        guard let self, let tab else { return nil }
        return self.registry.indicator(on: tab, terminals: terminals)
      })
  }

  func links(for tab: SessionTab) -> TerminalLinks {
    TerminalLinks(find: { [weak tab] in tab?.link(atRow: $0, column: $1) },
      actions: { [weak self, weak tab] link in
        guard let self, let tab else { return nil }
        return self.linkActions(for: PointedLink(link: link, directory: { [weak self, weak tab] in
          guard let self, let tab else { return nil }
          return await self.workingDirectory(for: link, on: tab)
        }), on: tab)
      })
  }

  private func workingDirectory(for link: TerminalLink?, on tab: SessionTab) async -> String? {
    for plugin in tabs.accessories { prepareAttachment(plugin.id, on: tab) }
    for item in tab.attachments {
      if let directory = await item.attachment.workingDirectory(for: link) { return directory }
    }
    return tab.workingDirectory
  }

  private func linkActions(for pointed: PointedLink, on tab: SessionTab) -> LinkActions? {
    let copy = PluginCommand(id: "copy", title: "Copy", symbol: "doc.on.doc") { copyToPasteboard(pointed.link.text) }
    if let url = webAddress(pointed.link) {
      let open = PluginCommand(id: "openLink", title: "Open Link", symbol: "safari") { Self.openURL(url) }
      return LinkActions(open: { Self.openURL(url) }, commands: [open, copy], exists: { true })
    }
    for plugin in tabs.accessories { prepareAttachment(plugin.id, on: tab) }
    let offers = tab.attachments.compactMap { $0.attachment.actions(for: pointed) }
    guard let combined = LinkActions.combining(offers) else { return LinkActions(commands: [copy], exists: { false }) }
    // Plugin link operations can present inspectors/previews, so they use the
    // same centralized workspace-only handoff as plugin commands.
    return LinkActions(open: combined.open.map { action in { _ = self.performOnWorkspace(action) } },
      preview: combined.preview.map { action in {
        guard self.performOnWorkspace({}) else { return AnyView(EmptyView()) }
        return action()
      } },
      commands: combined.commands.map { command in
        PluginCommand(id: command.id, title: command.title, symbol: command.symbol) { _ = self.performOnWorkspace(command.action) }
      } + [copy], exists: combined.exists)
  }

  private func webAddress(_ link: TerminalLink) -> URL? {
    let text: String
    switch link.kind {
    case .url(let url): text = url
    case .hyperlink(let uri): text = uri
    case .path: return nil
    }
    guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
    return url
  }

  private static func openURL(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
  }

  func drop(_ urls: [URL], on tab: SessionTab) {
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else { return }
    if tab.host.isLocal { tab.send(.paste(files.map { shellQuoted($0.path) }.joined(separator: " ") + " ")); return }
    for plugin in tabs.accessories { prepareAttachment(plugin.id, on: tab) }
    _ = performOnWorkspace {
      for attachment in tab.attachments { if attachment.attachment.receive(files: files) { break } }
    }
  }

  func launch(_ plugin: any TetherPlugin, from: UUID? = nil) {
    if let from, !claim(from) { return }
    _ = performOnWorkspace { self.launchOnWorkspace(plugin) }
  }

  private func launchOnWorkspace(_ plugin: any TetherPlugin) {
    let tab = tabs.current
    if plugin is any TabPlugin {
      guard let tab, tab.canOpen(plugin.metadata.id) else { return }
      tabs.toggleAccessory(plugin.metadata.id, on: tab.id)
      return
    }
    if plugin.needsRemoteConnection, tab?.connection == nil { return }
    let host = tab?.host
    plugin.launch(in: PluginContext(connection: tab?.connection,
      hostLabel: host.map { $0.label.isEmpty ? $0.hostname : $0.label } ?? "", hostID: host?.id ?? UUID(),
      shellLabel: shellLabel(for: tab), pluginID: plugin.metadata.id, pluginName: plugin.metadata.name,
      openWorkspace: { [weak self] workspace in
        self?.tabs.openExtension(workspace, pluginID: plugin.metadata.id, hostID: plugin.needsRemoteConnection ? host?.id : nil)
      }, reconnect: { [weak self] in
        guard let self, let host else { throw CancellationError() }
        return try await self.reconnect(host: host)
      }))
  }
}
