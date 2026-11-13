import FilesPlugin
import PortsPlugin
import SwiftUI
import Tether
import TetherPluginHost
import TetherPluginKit
import TetherUI
import TmuxPlugin
#if TETHER_NERVE
import NervePlugin
#endif

/// What the app holds for the life of the process, made once: the library,
/// the sessions, the plugins and the keychain. The Mac's window and the
/// phone's scene both show it.
@MainActor @Observable
final class AppModel {
  let store: HostStore
  let tabs: TabSet
  let registry: PluginRegistry
  let interaction: WorkspaceInteraction
  let plugins = PluginAPI(consent: DialogConsent())
  let imports = CredentialImport.shared
  /// One keychain for the process. Passwords are read at the moment of
  /// connecting and never held here (spec §18).
  let secrets: any SecretStore = Keychain()
  var installedPlugins: InstalledPlugins?
  /// Windows after the first. Each has its own tabs and does not rewrite the
  /// main window's session history.
  var additionalSessions: [TabSet] = []
  /// The key window's tabs. Menu commands follow it.
  var keyTabs: TabSet?
  var commandTabs: TabSet {
    #if os(macOS)
    if let key = NSApp?.keyWindow,
      let owner = ([tabs] + additionalSessions).first(where: { $0.interaction?.hostID(for: key) != nil }) {
      return owner
    }
    #endif
    return keyTabs ?? tabs
  }
  var openAdditionalWindow: (() -> Void)?

  init() {
    #if DEBUG
      let testDirectory = (Bundle.main.object(forInfoDictionaryKey: "TetherUITestDirectory") as? String)
        .map { URL(fileURLWithPath: $0) }
      let hostsFile = ProcessInfo.processInfo.environment["TETHER_HOSTS_FILE"]
    #else
      let testDirectory: URL? = nil
      let hostsFile: String? = nil
    #endif
    if let testDirectory {
      store = HostStore(location: testDirectory.appending(path: "hosts.json"))
      tabs = TabSet(historyStore: SessionHistoryStore(directory: testDirectory.appending(path: "history")))
    } else {
      store = hostsFile.map { HostStore(location: URL(fileURLWithPath: $0)) } ?? HostStore()
      tabs = TabSet(historyStore: SessionHistoryStore())
    }
    let registry = PluginRegistry()
    registry.register(TmuxPlugin())
    registry.register(FilesPlugin())
    registry.register(PortsPlugin())
    #if TETHER_NERVE
    registry.register(NervePlugin())
    #endif
    self.registry = registry
    interaction = WorkspaceInteraction(tabs: tabs, store: store, registry: registry, secrets: secrets)
    registry.onDisable = { [weak self] id in
      guard let self else { return }
      for tabs in [self.tabs] + self.additionalSessions { tabs.closePlugin(id) }
      PluginLive.end(id)
    }
    #if TETHER_NERVE
    // A row click in the hosted panel uses the same landing as the web page.
    // The panel is created above; the closure is read when the row is clicked.
    NervePlugin.focus = { [weak self] request in
      guard let self else { return false }
      let landed = self.land(
        host: request.host, terminal: request.terminal,
        directory: request.directory, url: request.url)
      return landed == "tab" || landed == "url"
    }
    #endif
  }

  /// A Nerve row, from the hosted panel or the web page. A shell tty is
  /// this window's tab. A pane tty is the plugin's, which still selects
  /// the tab that is showing that session.
  func land(host: String?, terminal: String?, directory: String?, url: String?) -> String {
    SessionFocus.land(
      host: host, terminal: terminal, directory: directory, url: url,
      sets: [tabs] + additionalSessions,
      claim: { host, terminal in
        registry.plugins.contains { $0.claimTerminal(host: host, terminal: terminal) }
      })
  }
}
