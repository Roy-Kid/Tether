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
  @State private var registry: PluginRegistry = {
    let registry = PluginRegistry()
    registry.register(TmuxPlugin())
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
      .windowToolbarStyle(.unified)
      .commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {
          Button("Close workspace") { if let id = tabs.selected { tabs.close(id) } }
            .keyboardShortcut("w").disabled(tabs.selected == nil)
        }
        CommandGroup(after: .appInfo) {
          ForEach(Tether.composition(), id: \.self) { part in
            Text(part)
          }
        }
      }

      // A separate scene, because that is where a Mac keeps preferences and
      // where ⌘, already goes.
      Settings { AppSettings(registry: registry) }
    #else
      // A phone has no preferences window and no menu bar; settings are
      // reached from the sidebar and presented over the app.
      WindowGroup {
        root
      }
    #endif
  }

  private var root: some View {
    RootView(store: store, tabs: tabs, registry: registry)
      .task {
        await Task.yield()
        openHostNamedOnCommandLine()
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
  func openHostNamedOnCommandLine() {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--open"),
      let name = arguments[safe: flag + 1]
    else { return }

    let wanted = name.lowercased()
    guard
      let host = store.hosts.first(where: {
        $0.label.lowercased() == wanted || $0.hostname.lowercased() == wanted
      })
    else { return }

    tabs.open(host, password: "")
  }
}

/// The open sessions.
@MainActor
@Observable
final class TabSet {
  var tabs: [SessionTab] = []
  var extensions: [WorkspaceEntry] = []
  var selected: SessionTab.ID?

  var current: SessionTab? {
    tabs.first { $0.id == selected }
  }

  /// The accepted host keys, shared by every session: trust belongs to the
  /// person and their machine, not to one tab.
  var known = KnownHosts()

  func open(_ host: Host, password: String) {
    let tab = SessionTab(host: host, password: password, known: known)
    tabs.append(tab)
    selected = tab.id
  }

  func closeAll() {
    tabs.forEach { $0.close() }
    extensions.forEach { $0.workspace.close() }
    tabs.removeAll()
    extensions.removeAll()
    selected = nil
  }
  func closePlugin(_ pluginID: String) {
    for entry in extensions.filter({ $0.pluginID == pluginID }) { close(entry.id) }
  }
  func close(_ id: SessionTab.ID) {
    if let index = extensions.firstIndex(where: { $0.id == id }) {
      extensions[index].workspace.close()
      extensions.remove(at: index)
      if selected == id { selected = extensions.last?.id ?? tabs.last?.id }
      return
    }
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].close()
    tabs.remove(at: index)

    // Select the neighbour rather than nothing, so closing a tab in the
    // middle of a row does not empty the window.
    if selected == id {
      selected = tabs[safe: index]?.id ?? tabs.last?.id ?? extensions.last?.id
    }
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
