#if os(macOS)
  import NervePlugin
#endif
import FilesPlugin
import SwiftUI
import Tether
import TetherPluginKit
import TmuxPlugin

@main
struct TetherApp: App {
  @State private var store: HostStore = {
    #if DEBUG
      if let path = ProcessInfo.processInfo.environment["TETHER_HOSTS_FILE"] {
        return HostStore(location: URL(fileURLWithPath: path))
      }
    #endif
    return HostStore()
  }()
  @State private var tabs = TabSet()
  /// One keychain for the process. Passwords are read at the moment of
  /// connecting and never held here (spec §18).
  private let secrets: any SecretStore = Keychain()
  @Environment(\.scenePhase) private var phase
  @State private var registry: PluginRegistry = {
    let registry = PluginRegistry()
    registry.register(TmuxPlugin())
    registry.register(FilesPlugin())
    #if os(macOS)
      registry.register(NervePlugin())
    #endif
    return registry
  }()

  var body: some Scene {
    #if os(macOS)
      // A single window, not a `WindowGroup`: the sidebar is the document
      // picker, so a second empty window would be a second copy of the same
      // host list with nothing open in it.
      Window("Tether", id: "main") {
        root
          .frame(minWidth: 860, minHeight: 520)
      }
      // `.contentSize` would bind the window to the content's *ideal* size,
      // and a terminal has no ideal size — measured: the window opened
      // 44×89 points, off the bottom-left corner of the screen.
      .defaultSize(width: 1100, height: 700)
      .windowResizability(.contentMinSize)
      .windowStyle(.hiddenTitleBar)
      .commands {
        WorkspaceCommands(tabs: tabs)
      }

      // A separate scene, because that is where a Mac keeps preferences and
      // where ⌘, already goes.
      Settings {
        AppSettings(registry: registry, known: tabs.known, store: store, secrets: secrets)
      }
    #else
      // A phone has no preferences window and no menu bar; settings are
      // reached from the sidebar and presented over the app.
      WindowGroup {
        root
      }
    #endif
  }

  private var root: some View {
    RootView(store: store, tabs: tabs, registry: registry, secrets: secrets)
      .task {
        await Task.yield()
        // The command line wins. Someone who typed `--open lab` asked for a
        // specific machine, and answering with a different one would be the
        // app overruling them.
        if !openHostNamedOnCommandLine() {
          openLocalAtLaunch()
        }
      }
      // The host list is `~/.ssh/config`, which belongs to the person rather
      // than to this app: they may well have added a stanza in an editor
      // while this was in the background. Coming back to the front is when
      // that is worth finding out.
      .onChange(of: phase) { _, phase in
        if phase == .active { store.reload() }
      }
  }
}

extension TetherApp {
  /// `Tether.app --open lab` connects to a saved host on launch.
  ///
  /// The equivalent of typing `ssh lab`: someone who already knows which
  /// machine they want should not have to find it in a list. Only saved
  /// hosts, and only ones with a key or an interactive server — there is
  /// nowhere on a command line to put a password that would not end up in
  /// a shell history.
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

    tabs.open(host, password: "")
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


