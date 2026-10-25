#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif
import AuthenticationServices
import FilesPlugin
import UserNotifications
import PortsPlugin
import SwiftUI
import Tether
import TetherUI
import TetherPluginHost
import TetherPluginKit
import TmuxPlugin

#if os(macOS)
  /// The main window is put away rather than closed. Additional windows are
  /// real windows: each has its own tabs, and the red button ends them.
  private final class ExtraWindow {
    let tabs: TabSet
    let window: WorkspaceWindow
    var closeObserver: NSObjectProtocol?
    init(tabs: TabSet, window: WorkspaceWindow) {
      self.tabs = tabs
      self.window = window
    }
  }

  /// One window starts as the app. Closing it must not quit: the icon stays
  /// in the Dock, the window is put away with every tab in it, and a click on
  /// the icon brings it back (`HideInsteadOfClose`).
  ///
  /// The window is made here, not by a scene: SwiftUI's own window cannot
  /// be the panel the quick terminal is shown as (`WorkspaceWindow`).
  @MainActor
  final class TetherAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var window: WorkspaceWindow?
    private var extras: [ExtraWindow] = []
    private lazy var quitGate = QuitGate()

    func applicationDidFinishLaunching(_ notification: Notification) {
      let window = WorkspaceWindow(hosting: RootHost(model: model))
      self.window = window
      model.openAdditionalWindow = { [weak self] in self?.openAdditionalWindow() }
      let quick = model.tabs.quickTerminal
      quick.attachMain(window)
      quick.provide { [weak self] in self?.makeQuickTerminal() ?? NSPanel() }
      quick.useBindings(model.tabs.keyBindings)
      window.makeKeyAndOrderFront(nil)
      // Launch activated the app before it had a window, which brings no
      // Space forward. Now that it has one, once more — measured: launched
      // behind another app's full-screen Space, the window stayed behind it.
      NSApp.activate(ignoringOtherApps: true)
      UNUserNotificationCenter.current().delegate = self
      Task { await NotificationPermission.askIfNeeded() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      let live = model.tabs.liveTerminalCount + model.additionalSessions.reduce(0) { $0 + $1.liveTerminalCount }
      return quitGate.shouldTerminate(sender, live: live)
    }

    func applicationWillTerminate(_ notification: Notification) {
      model.tabs.quickTerminal.stop()
      for extra in extras { extra.tabs.closeAll() }
    }

    /// The quick terminal: a panel of its own showing the main window's
    /// tabs, so the two share every tab and session and neither moves or
    /// hides the other. Made the first time it is asked for. Closing it puts
    /// it away like hiding it does.
    private func makeQuickTerminal() -> NSWindow {
      WorkspaceWindow(hosting: RootHost(model: model, primary: false), autosaveName: nil)
    }

    /// Another workspace window. It has its own tabs and does not hide in
    /// place of closing, and it does not rewrite the main window's history.
    func openAdditionalWindow() {
      let tabs = TabSet()
      tabs.quickTerminal = model.tabs.quickTerminal
      let window = WorkspaceWindow(
        hosting: RootHost(model: model, ownedSessions: tabs)
          .environment(\.workspaceHidesOnClose, false),
        autosaveName: nil)
      window.isReleasedWhenClosed = true
      if let main = self.window {
        window.setFrame(main.frame.offsetBy(dx: 32, dy: -32), display: false)
      }
      let extra = ExtraWindow(tabs: tabs, window: window)
      extras.append(extra)
      model.additionalSessions.append(tabs)
      extra.closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.closeExtra(window) }
      }
      window.makeKeyAndOrderFront(nil)
    }

    private func closeExtra(_ window: NSWindow) {
      guard let index = extras.firstIndex(where: { $0.window === window }) else { return }
      let tabs = extras[index].tabs
      extras.remove(at: index)
      model.additionalSessions.removeAll { $0 === tabs }
      if model.keyTabs === tabs { model.keyTabs = nil }
      tabs.closeAll()
    }

    /// The main window, not just any: with Settings open and the main
    /// window put away, the icon still means the terminals. Answered here,
    /// so nothing else opens a second window for the same scene. The quick
    /// terminal is not it either: the Dock is how a person asks for a
    /// window, the shortcut how they ask for the quick terminal.
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
    @UIApplicationDelegateAdaptor(TetherPhoneDelegate.self) private var phoneDelegate
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
        WorkspaceCommands(model: model)
      }
    #else
      // A phone has no preferences window and no menu bar; settings are
      // reached from the sidebar and presented over the app.
      WindowGroup {
        RootHost(model: model)
      }
      .commands { WorkspaceCommands(model: model) }
    #endif
  }
}

#if os(iOS)
  /// A note posted while Tether is in front stays on the page. One that arrives
  /// as the app is leaving still has to be allowed onto the screen.
  @MainActor
  final class TetherPhoneDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      UNUserNotificationCenter.current().delegate = self
      return true
    }

    nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
      completionHandler([.banner, .sound, .list])
    }
  }
#endif

extension Notification.Name {
  /// A status row landed on a terminal. The panel gets out of the way.
  static let closePluginPanel = Notification.Name("Tether.closePluginPanel")
}

/// An editor a job already named. A directory is not opened here: that launches Finder.
enum FocusLink {
  private static let schemes: Set<String> = [
    "vscode", "vscode-insiders", "cursor", "windsurf", "zed", "jetbrains",
  ]

  static func url(_ raw: String) -> URL? {
    guard raw.count <= 2048, let url = URL(string: raw),
      let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
    return url
  }
}

#if os(macOS)
/// A tty that belongs to Terminal.app, not to a tab in this process.
enum ExternalTerminal {
  static func focus(device: String) -> Bool {
    guard let source = script(device: device) else { return false }
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil && result?.booleanValue == true
  }

  /// `device` is interpolated into AppleScript, so it has to be a bare tty path.
  static func script(device: String) -> String? {
    guard device.range(of: #"^/dev/(ttys\d+|pts/\d+)$"#, options: .regularExpression) != nil else {
      return nil
    }
    return """
    tell application "Terminal"
      if not running then return false
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is "\(device)" then
            set selected tab of w to t
            set index of w to 1
            activate
            return true
          end if
        end repeat
      end repeat
      return false
    end tell
    """
  }
}
#endif

/// The whole app's view, with what happens around it as it comes up, as the
/// library changes and as attention comes and goes. The same everywhere;
/// only the window or scene around it differs.
struct RootHost: View {
  @Bindable var model: AppModel
  /// Nil on the main window, which keeps `model.tabs`. An additional window
  /// passes its own set and closes for real.
  var ownedSessions: TabSet? = nil
  /// False for the quick terminal: the main window's tabs in a second
  /// window, which must not open them, import, or sync a second time.
  var primary = true
  private var windowTabs: TabSet { ownedSessions ?? model.tabs }
  /// The window that starts the app: the main window's tabs, in the main window.
  private var isPrimary: Bool { ownedSessions == nil && primary }
  #if os(iOS)
    @Environment(\.scenePhase) private var phase
  #endif

  var body: some View {
    RootView(store: model.store, tabs: windowTabs, registry: model.registry, secrets: model.secrets,
      plugins: model.plugins, installedPlugins: $model.installedPlugins)
      .task {
        // First, so the keychain is listed before anything on screen could
        // be holding a key it has not saved yet.
        Task { await model.store.sweepCredentials() }
        if model.installedPlugins == nil {
          let library = InstalledPlugins(
            directory: InstalledPlugins.defaultDirectory, registry: model.registry, host: PluginHost(api: model.plugins))
          model.plugins.onStatus = { [registry = model.registry] id, item in
            let plugin = registry.plugins.first { $0.metadata.id == id }
            plugin?.receiveStatus(item)
            PluginLive.note(
              pluginID: id, name: plugin?.metadata.name ?? item.label, label: item.label, segments: item.segments)
          }
          library.onFocus = { request in
            let sets = [model.tabs] + model.additionalSessions
            if let terminal = request.terminal {
              if sets.contains(where: { $0.focusSession(host: request.host, terminal: terminal, directory: nil) }) {
                NotificationCenter.default.post(name: .closePluginPanel, object: nil)
                return "tab"
              }
              #if os(macOS)
                if let host = request.host,
                  TabSet.sameMachine(host, LocalMachine.kernelName),
                  ExternalTerminal.focus(device: terminal)
                {
                  NotificationCenter.default.post(name: .closePluginPanel, object: nil)
                  return "tab"
                }
              #endif
              return "none"
            }
            if sets.contains(where: { $0.focusSession(host: nil, terminal: nil, directory: request.directory) }) {
              NotificationCenter.default.post(name: .closePluginPanel, object: nil)
              return "tab"
            }
            #if os(macOS)
              if let raw = request.url, let url = FocusLink.url(raw), NSWorkspace.shared.open(url) {
                return "url"
              }
            #endif
            return "none"
          }
          model.installedPlugins = library
          library.discover()
          #if os(iOS)
            await NotificationPermission.askIfNeeded()
            PluginLive.adopt()
          #endif
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
        windowTabs.reconcileClosedTabs(with: model.store.hosts)
        windowTabs.keyBindings.register(KeyBindingCatalog.commands(registry: model.registry))
        if isPrimary { model.store.useKeyBindings(windowTabs.keyBindings) }
        if ownedSessions != nil, windowTabs.tabs.isEmpty {
          windowTabs.open(.local, password: "")
        }
        await Task.yield()
        // The first terminal waits for nothing slow: the library on this
        // device is already read, and a shell here needs nothing else.
        if isPrimary { await openAtLaunch() }
        // Then the SSH file and the keychain, off the main actor. Ask before
        // copying ~/.ssh/config over the library. The file is not written.
        // An additional window shares this library; it does not import again.
        if isPrimary {
          await model.store.refresh()
          model.store.offerConfigurationImport()
          await model.store.startSync()
        }
      }
      .onChange(of: model.registry.plugins.map(\.metadata.id)) { _, _ in
        windowTabs.keyBindings.register(KeyBindingCatalog.commands(registry: model.registry))
      }
      .onChange(of: model.store.hosts) { _, hosts in
        windowTabs.reconcileClosedTabs(with: hosts)
        // A synchronized endpoint or policy change invalidates an in-flight
        // attempt and its old lease. Stale tabs cannot keep granting channels.
        for tab in windowTabs.tabs where tab.host.isManaged {
          let current = hosts.first { $0.id == tab.host.id }
          if current?.sameSessionTarget(as: tab.host) != true { windowTabs.close(tab.id, remember: false) }
        }
      }
      .onChange(of: model.store.accountGeneration) { _, _ in windowTabs.closeAccountSessions() }
      .dialog(for: isPrimary ? model.imports.notice : nil) { notice in
        Dialog.notice(notice.title, message: notice.message) { model.imports.notice = nil }
      }
      #if os(macOS)
        // Attention is the window being key. The overlay is worked in
        // without the app ever becoming active, so the app's state says nothing.
        .background {
          WindowState { value in
            if value.key { model.keyTabs = windowTabs }
            else if model.keyTabs === windowTabs {
              // Two windows can show these tabs. Cleared only once neither
              // is key, after both have reported (`TabSet.note`).
              DispatchQueue.main.async {
                if windowTabs.keyWindows.isEmpty, model.keyTabs === windowTabs { model.keyTabs = nil }
              }
            }
            attend(value.key)
          }
          .allowsHitTesting(false)
        }
        .environment(\.workspaceHidesOnClose, isPrimary)
      #else
        .onChange(of: phase) { _, phase in attend(phase == .active) }
        .onContinueUserActivity(ASCredentialExchangeActivity) { model.imports.receive($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
          for tab in windowTabs.tabs { tab.releaseHistory() }
        }
      #endif
  }

  /// Coming forward reads the library through iCloud again. The SSH file
  /// is imported only from the question at open, or from Settings. Going
  /// away, the histories are written.
  private func attend(_ attentive: Bool) {
    if !attentive { windowTabs.checkpointHistory() }
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

    windowTabs.intent = .connect(host)
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
      windowTabs.tabs.isEmpty
    else { return }

    windowTabs.open(.local, password: "")
  }
}
