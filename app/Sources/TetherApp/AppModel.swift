import FilesPlugin
import PortsPlugin
import SwiftUI
import Tether
import TetherPluginHost
import TetherPluginKit
import TetherUI
import TmuxPlugin
#if os(macOS)
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
  var commandTabs: TabSet { keyTabs ?? tabs }
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
    #if os(macOS)
    registry.register(NervePlugin())
    #endif
    self.registry = registry
  }
}
