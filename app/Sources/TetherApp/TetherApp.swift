#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif
import AuthenticationServices
import FilesPlugin
import PortsPlugin
import SwiftUI
import Tether
import TetherUI
import TetherPluginHost
import TetherPluginKit
import TmuxPlugin

#if os(macOS)
  /// One window is the whole app. Closing it must not quit: the icon stays
  /// in the Dock, the window is put away with every tab in it, and a click on
  /// the icon brings it back (`HideInsteadOfClose`).
  final class TetherAppDelegate: NSObject, NSApplicationDelegate {
    /// The sessions a quit would end. Handed over once the window exists.
    weak var tabs: TabSet?
    private lazy var quitGate = QuitGate()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      MainActor.assumeIsolated { quitGate.shouldTerminate(sender, tabs: tabs) }
    }

    /// The main window, not just any: with Settings open and the main
    /// window put away, the icon still means the terminals. Answered here,
    /// so nothing else opens a second window for the same scene.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
      guard let window = HideInsteadOfClose.mainWindow(in: sender) else { return true }
      return !HideInsteadOfClose.reveal(window)
    }

    /// A password manager's export, chosen in the password manager. Taken
    /// here rather than by the window: a Mac hands a user activity to the
    /// application, and the window may be put away. It is read in Settings.
    func application(_ application: NSApplication, willContinueUserActivityWithType type: String) -> Bool {
      type == ASCredentialExchangeActivity
    }

    func application(_ application: NSApplication, continue activity: NSUserActivity,
      restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
      MainActor.assumeIsolated { CredentialImport.shared.receive(activity) }
    }
  }
#endif

@main
struct TetherApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(TetherAppDelegate.self) private var appDelegate
  #endif
  @State private var store: HostStore = {
    #if DEBUG
      if let directory = Bundle.main.object(forInfoDictionaryKey: "TetherUITestDirectory") as? String {
        return HostStore(location: URL(fileURLWithPath: directory).appending(path: "hosts.json"))
      }
      if let path = ProcessInfo.processInfo.environment["TETHER_HOSTS_FILE"] {
        return HostStore(location: URL(fileURLWithPath: path))
      }
    #endif
    return HostStore()
  }()
  @State private var tabs: TabSet = {
    #if DEBUG
      if let directory = Bundle.main.object(forInfoDictionaryKey: "TetherUITestDirectory") as? String {
        return TabSet(historyStore: SessionHistoryStore(directory: URL(fileURLWithPath: directory).appending(path: "history")))
      }
    #endif
    return TabSet(historyStore: SessionHistoryStore())
  }()
  /// One keychain for the process. Passwords are read at the moment of
  /// connecting and never held here (spec §18).
  private let secrets: any SecretStore = Keychain()
  @Environment(\.scenePhase) private var phase
  @State private var registry: PluginRegistry = {
    let registry = PluginRegistry()
    registry.register(TmuxPlugin())
    registry.register(FilesPlugin())
    registry.register(PortsPlugin())
    return registry
  }()

  @State private var plugins = PluginAPI(consent: DialogConsent())
  @State private var imports = CredentialImport.shared
  @State private var installedPlugins: InstalledPlugins?

  var body: some Scene {
    #if os(macOS)
      // A single window, not a `WindowGroup`: the sidebar is the document
      // picker, so a second empty window would be a second copy of the same
      // host list with nothing open in it.
      Window("Tether", id: "main") {
        root
          .frame(minWidth: Chrome.windowMinWidth, minHeight: Chrome.windowMinHeight)
          .onAppear { appDelegate.tabs = tabs }
      }
      // `.contentSize` would bind the window to the content's *ideal* size,
      // and a terminal has no ideal size — measured: the window opened
      // 44×89 points, off the bottom-left corner of the screen.
      .defaultSize(width: Chrome.windowWidth, height: Chrome.windowHeight)
      .windowResizability(.contentMinSize)
      .windowStyle(.hiddenTitleBar)
      .commands {
        WorkspaceCommands(tabs: tabs)
      }

      // A separate scene, because that is where a Mac keeps preferences and
      // where ⌘, already goes.
      Settings {
        AppSettings(registry: registry, known: tabs.known, store: store, secrets: secrets, connections: tabs, installedPlugins: installedPlugins)
          .background {
            WorkspaceKeyBindingMonitor(enabled: false, textEditingEnabled: true) { _, _, _ in false }
              .allowsHitTesting(false)
          }
      }
      .defaultSize(width: Chrome.settingsWidth, height: Chrome.settingsHeight)
      .windowResizability(.contentMinSize)
    #else
      // A phone has no preferences window and no menu bar; settings are
      // reached from the sidebar and presented over the app.
      WindowGroup {
        root
      }
      .commands { WorkspaceCommands(tabs: tabs) }
    #endif
  }

  private var root: some View {
    RootView(store: store, tabs: tabs, registry: registry, secrets: secrets, plugins: plugins, installedPlugins: $installedPlugins)
      .task {
        // First, so the keychain is listed before anything on screen could
        // be holding a key it has not saved yet.
        Task { await store.sweepCredentials() }
        if installedPlugins == nil {
          let library = InstalledPlugins(
            directory: InstalledPlugins.defaultDirectory, registry: registry, host: PluginHost(api: plugins))
          plugins.onStatus = { [registry] id, item in
            registry.plugins.first { $0.metadata.id == id }?.receiveStatus(item)
          }
          installedPlugins = library
          library.discover()
          #if os(macOS)
            if let flag = CommandLine.arguments.firstIndex(of: "--install-plugin"),
              CommandLine.arguments.indices.contains(flag + 1) {
              do { try await library.install(directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) }
              catch PluginHostError.consentDenied { }
              catch {
                await plugins.notify(title: "Could Not Install Plugin", body: error.localizedDescription)
              }
            }
          #endif
        }
        tabs.reconcileClosedTabs(with: store.hosts)
        tabs.keyBindings.register(KeyBindingCatalog.commands(registry: registry))
        store.useKeyBindings(tabs.keyBindings)
        await Task.yield()
        // The first terminal waits for nothing slow: the library on this
        // device is already read, and a shell here needs nothing else.
        await openAtLaunch()
        // Then the SSH file and the keychain, off the main actor. Ask before
        // copying ~/.ssh/config over the library. The file is not written.
        await store.refresh()
        store.offerConfigurationImport()
        // iCloud last: account status, the user record and a full fetch can
        // take seconds on a slow network, and nothing above needs them.
        await store.startSync()
      }
      .onChange(of: registry.plugins.map(\.metadata.id)) { _, _ in
        tabs.keyBindings.register(KeyBindingCatalog.commands(registry: registry))
      }
      .onChange(of: store.hosts) { _, hosts in
        tabs.reconcileClosedTabs(with: hosts)
        // A synchronized endpoint or policy change invalidates an in-flight
        // attempt and its old lease. Stale tabs cannot keep granting channels.
        for tab in tabs.tabs where tab.host.isManaged {
          let current = hosts.first { $0.id == tab.host.id }
          if current?.sameSessionTarget(as: tab.host) != true { tabs.close(tab.id, remember: false) }
        }
      }
      .onChange(of: store.accountGeneration) { _, _ in tabs.closeAccountSessions() }
      .dialog(for: imports.notice) { notice in
        Dialog.notice(notice.title, message: notice.message) { imports.notice = nil }
      }
      // Coming forward reads the library through iCloud again. The SSH
      // file is imported only from the question at open, or from Settings.
      .onChange(of: phase) { _, phase in
        plugins.deliversSystemNotes = phase != .active
        if phase != .active { tabs.checkpointHistory() }
        if phase == .active {
          Task {
            await store.refresh()
            await store.startSync()
            await store.syncNow()
          }
        }
      }
      #if os(iOS)
        .onContinueUserActivity(ASCredentialExchangeActivity) { imports.receive($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
          for tab in tabs.tabs { tab.releaseHistory() }
        }
      #endif
  }
}

extension TetherApp {
  /// The host named on the command line, or else this machine.
  ///
  /// The command line wins. Someone who typed `--open lab` asked for a
  /// specific machine, and answering with a different one would be the app
  /// overruling them. A name this device's library does not have yet may be
  /// one iCloud is about to bring, so only then does launch wait for iCloud
  /// before settling for this machine.
  @MainActor
  func openAtLaunch() async {
    if openHostNamedOnCommandLine() { return }
    if CommandLine.arguments.contains("--open") {
      await store.startSync()
      if openHostNamedOnCommandLine() { return }
    }
    openLocalAtLaunch()
  }

  /// `Tether.app --open lab` connects to a saved host on launch.
  ///
  /// The equivalent of typing `ssh lab`: someone who already knows which
  /// machine they want should not have to find it in a list. Only saved
  /// hosts, and opened the way a click opens them — with the same password
  /// question when one is needed, since there is nowhere on a command line
  /// to put a password that would not end up in a shell history.
  @MainActor
  @discardableResult
  func openHostNamedOnCommandLine() -> Bool {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--open"),
      let name = arguments[safe: flag + 1]
    else { return false }

    let wanted = name.lowercased()
    // `listed` rather than `hosts`, so `--open localhost` reaches the machine
    // this is running on like any other name in the sidebar does.
    guard
      let host = store.listed.first(where: {
        $0.label.lowercased() == wanted || $0.hostname.lowercased() == wanted
      })
    else { return false }

    tabs.intent = .connect(host)
    return true
  }

  /// Opens a terminal on this machine, unless someone turned that off.
  ///
  /// The one host that needs no password, no key and no host key to trust, so
  /// it is the only one that can be opened without asking a person anything.
  /// Everything else in the list would need a sheet first, which is not a
  /// thing to do to a window that has only just appeared.
  @MainActor
  func openLocalAtLaunch() {
    guard TerminalSession.isLocalAvailable,
      UserDefaults.standard.object(forKey: LaunchPreference.key) as? Bool
        ?? LaunchPreference.default,
      tabs.tabs.isEmpty
    else { return }

    tabs.open(.local, password: "")
  }
}
