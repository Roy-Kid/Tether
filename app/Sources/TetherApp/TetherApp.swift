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
  ///
  /// The window is made here, not by a scene: SwiftUI's own window cannot
  /// be the panel the quick terminal is shown as (`WorkspaceWindow`).
  @MainActor
  final class TetherAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var window: WorkspaceWindow?
    private lazy var quitGate = QuitGate()

    func applicationDidFinishLaunching(_ notification: Notification) {
      let window = WorkspaceWindow(hosting: RootHost(model: model))
      self.window = window
      model.tabs.quickTerminal.attach(to: window)
      model.tabs.quickTerminal.useBindings(model.tabs.keyBindings)
      window.makeKeyAndOrderFront(nil)
      // Launch activated the app before it had a window, which brings no
      // Space forward. Now that it has one, once more — measured: launched
      // behind another app's full-screen Space, the window stayed behind it.
      NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      quitGate.shouldTerminate(sender, tabs: model.tabs)
    }

    func applicationWillTerminate(_ notification: Notification) {
      model.tabs.quickTerminal.stop()
    }

    /// The main window, not just any: with Settings open and the main
    /// window put away, the icon still means the terminals. Answered here,
    /// so nothing else opens a second window for the same scene. And the
    /// ordinary window, not the overlay: the Dock is how a person asks for
    /// a window, the shortcut how they ask for the quick terminal.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
      if model.tabs.quickTerminal.reopen() { return false }
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
      CredentialImport.shared.receive(activity)
    }
  }
#endif

@main
struct TetherApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(TetherAppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }
  #else
    @State private var model = AppModel()
  #endif

  var body: some Scene {
    #if os(macOS)
      // The workspace window is the delegate's, not a scene's. Settings
      // stays one, because that is where a Mac keeps preferences and where
      // ⌘, already goes; the menus hang off it.
      Settings {
        AppSettings(registry: model.registry, known: model.tabs.known, store: model.store, secrets: model.secrets,
          connections: model.tabs, installedPlugins: model.installedPlugins)
          .background {
            WorkspaceKeyBindingMonitor(enabled: false, textEditingEnabled: true) { _, _, _ in false }
              .allowsHitTesting(false)
          }
      }
      .defaultSize(width: Chrome.settingsWidth, height: Chrome.settingsHeight)
      .windowResizability(.contentMinSize)
      .commands {
        WorkspaceCommands(tabs: model.tabs)
      }
    #else
      // A phone has no preferences window and no menu bar; settings are
      // reached from the sidebar and presented over the app.
      WindowGroup {
        RootHost(model: model)
      }
      .commands { WorkspaceCommands(tabs: model.tabs) }
    #endif
  }
}

/// The whole app's view, with what happens around it as it comes up, as the
/// library changes and as attention comes and goes. The same everywhere;
/// only the window or scene around it differs.
struct RootHost: View {
  @Bindable var model: AppModel
  #if os(iOS)
    @Environment(\.scenePhase) private var phase
  #endif

  var body: some View {
    RootView(store: model.store, tabs: model.tabs, registry: model.registry, secrets: model.secrets,
      plugins: model.plugins, installedPlugins: $model.installedPlugins)
      .task {
        // First, so the keychain is listed before anything on screen could
        // be holding a key it has not saved yet.
        Task { await model.store.sweepCredentials() }
        if model.installedPlugins == nil {
          let library = InstalledPlugins(
            directory: InstalledPlugins.defaultDirectory, registry: model.registry, host: PluginHost(api: model.plugins))
          model.plugins.onStatus = { [registry = model.registry] id, item in
            registry.plugins.first { $0.metadata.id == id }?.receiveStatus(item)
          }
          model.installedPlugins = library
          library.discover()
          #if os(macOS)
            if let flag = CommandLine.arguments.firstIndex(of: "--install-plugin"),
              CommandLine.arguments.indices.contains(flag + 1) {
              do { try await library.install(directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) }
              catch PluginHostError.consentDenied { }
              catch {
                await model.plugins.notify(title: "Could Not Install Plugin", body: error.localizedDescription)
              }
            }
          #endif
        }
        model.tabs.reconcileClosedTabs(with: model.store.hosts)
        model.tabs.keyBindings.register(KeyBindingCatalog.commands(registry: model.registry))
        model.store.useKeyBindings(model.tabs.keyBindings)
        await Task.yield()
        // The first terminal waits for nothing slow: the library on this
        // device is already read, and a shell here needs nothing else.
        await openAtLaunch()
        // Then the SSH file and the keychain, off the main actor. Ask before
        // copying ~/.ssh/config over the library. The file is not written.
        await model.store.refresh()
        model.store.offerConfigurationImport()
        // iCloud last: account status, the user record and a full fetch can
        // take seconds on a slow network, and nothing above needs them.
        await model.store.startSync()
      }
      .onChange(of: model.registry.plugins.map(\.metadata.id)) { _, _ in
        model.tabs.keyBindings.register(KeyBindingCatalog.commands(registry: model.registry))
      }
      .onChange(of: model.store.hosts) { _, hosts in
        model.tabs.reconcileClosedTabs(with: hosts)
        // A synchronized endpoint or policy change invalidates an in-flight
        // attempt and its old lease. Stale tabs cannot keep granting channels.
        for tab in model.tabs.tabs where tab.host.isManaged {
          let current = hosts.first { $0.id == tab.host.id }
          if current?.sameSessionTarget(as: tab.host) != true { model.tabs.close(tab.id, remember: false) }
        }
      }
      .onChange(of: model.store.accountGeneration) { _, _ in model.tabs.closeAccountSessions() }
      .dialog(for: model.imports.notice) { notice in
        Dialog.notice(notice.title, message: notice.message) { model.imports.notice = nil }
      }
      #if os(macOS)
        // Attention is the window being key. The overlay is worked in
        // without the app ever becoming active, so the app's state says nothing.
        .background { WindowState { attend($0.key) }.allowsHitTesting(false) }
      #else
        .onChange(of: phase) { _, phase in attend(phase == .active) }
        .onContinueUserActivity(ASCredentialExchangeActivity) { model.imports.receive($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
          for tab in model.tabs.tabs { tab.releaseHistory() }
        }
      #endif
  }

  /// Coming forward reads the library through iCloud again. The SSH file
  /// is imported only from the question at open, or from Settings. Going
  /// away, the histories are written and notes go to the system.
  private func attend(_ attentive: Bool) {
    model.plugins.deliversSystemNotes = !attentive
    if !attentive { model.tabs.checkpointHistory() }
    if attentive {
      Task {
        await model.store.refresh()
        await model.store.startSync()
        await model.store.syncNow()
      }
    }
  }
}

extension RootHost {
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
      await model.store.startSync()
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
      let host = model.store.listed.first(where: {
        $0.label.lowercased() == wanted || $0.hostname.lowercased() == wanted
      })
    else { return false }

    model.tabs.intent = .connect(host)
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
      model.tabs.tabs.isEmpty
    else { return }

    model.tabs.open(.local, password: "")
  }
}
