import SwiftUI
import Tether
import TetherPluginKit

/// tmux, as a tab plugin: every terminal tab carries a menu. The session
/// itself is whatever tmux draws in that tab's ordinary terminal.
///
/// The plugin is where the tabs meet. It knows every tab it is attached to,
/// which is what "a session belongs to one tab" needs and what the host,
/// which does not know what a session is, could not answer.
@MainActor @Observable
public final class TmuxPlugin: TabPlugin {
  public static let id = "dev.tether.tmux"
  /// The plugin's mark, on its metadata, its accessory and a tab running tmux.
  static let symbol = "rectangle.3.offgrid"
  public let metadata = PluginMetadata(
    id: TmuxPlugin.id, name: "tmux", symbol: TmuxPlugin.symbol,
    summary: "Persistent sessions, in the terminal itself.")
  /// Beside Files on a Mac: the host draws one status-bar button per inspector
  /// accessory. A phone has no status bar, so the shell button keeps the picker.
  public let accessory = TabAccessory(
    symbol: TmuxPlugin.symbol, name: "tmux sessions",
    placement: {
      #if os(macOS)
        .inspector
      #else
        .popover
      #endif
    }())
  /// The splits propose the chords the host's own splits use: on a tab whose
  /// shell is a tmux client, splitting means splitting tmux. Elsewhere the
  /// host keeps them.
  public let commandDescriptors = [
    PluginCommandDescriptor(id: "detach", title: "Detach Session"),
    PluginCommandDescriptor(id: "newWindow", title: "New Window", shortcut: PluginKeyChord("n", [.command, .shift])),
    PluginCommandDescriptor(id: "previousWindow", title: "Previous Window",
                            shortcut: PluginKeyChord("[", [.command, .option])),
    PluginCommandDescriptor(id: "nextWindow", title: "Next Window", shortcut: PluginKeyChord("]", [.command, .option])),
    PluginCommandDescriptor(id: "splitHorizontal", title: "Split Left and Right", shortcut: PluginKeyChord("\\")),
    PluginCommandDescriptor(id: "splitVertical", title: "Split Top and Bottom",
                            shortcut: PluginKeyChord("\\", [.command, .shift])),
    PluginCommandDescriptor(id: "zoom", title: "Zoom Pane", shortcut: PluginKeyChord("return", [.command, .shift])),
  ] + TmuxPaneDirection.allCases.map {
    PluginCommandDescriptor(id: $0.commandID, title: $0.title, shortcut: PluginKeyChord($0.key, [.command, .option]))
  } + (1...4).map { number in
    PluginCommandDescriptor(
      id: "session\(number)", title: "Session \(number)",
      shortcut: PluginKeyChord("\(number)", [.option]))
  }
  private var tabs: [UUID: TmuxTab] = [:]
  /// The last list read on a host. Every terminal there shows it: a shell
  /// beside a client is still that host, and its own read may not have
  /// landed yet.
  private var sessionsByHost: [UUID: [TmuxSessionInfo]] = [:]
  /// Pane tty to the session that owns it, per host: the one list of panes.
  /// A Nerve row names a pane, and so does a status mark; the shell's own tty
  /// is only the client in front of it. Observed, so a session's dot and
  /// the tab showing it follow a new read.
  private var panesByHost: [UUID: [(tty: String, session: String)]] = [:]
  /// One client list per host. Switching inside tmux never passes through a menu,
  /// so the server is asked while any terminal on that host is still connected.
  private var clientWatch: [UUID: Task<Void, Never>] = [:]

  public init() {}

  public func attach(to tab: TabContext) -> any TabAttachment {
    let id = tab.id
    let host = tab.plugin.hostID
    let attached = TmuxTab(
      tab: tab,
      owner: { [weak self] session in self?.tab(owning: session, on: host) },
      onClose: { [weak self] in self?.tabs[id] = nil },
      rememberSessions: { [weak self] sessions in self?.remember(sessions, on: host) },
      recalledSessions: { [weak self] in self?.rememberedSessions(on: host) ?? [] },
      rememberPanes: { [weak self] panes in self?.remember(panes, on: host) },
      recalledPanes: { [weak self] in self?.panesByHost[host] ?? [] },
      onConnected: { [weak self] in self?.ensureClientWatch(host: host) })
    tabs[id] = attached
    if tab.plugin.connection != nil { ensureClientWatch(host: host) }
    return attached
  }

  /// Asks which session each of this host's terminals is showing. One command
  /// for the host, on a tab that is not itself switching. A failed command
  /// waits longer and changes nothing: tmux not being there is not a detach.
  private func ensureClientWatch(host: UUID) {
    guard clientWatch[host] == nil else { return }
    clientWatch[host] = Task { [weak self] in
      var pause: Duration = .seconds(1)
      while !Task.isCancelled {
        try? await Task.sleep(for: pause)
        guard let self, !Task.isCancelled else { return }
        let live = self.tabs.values.filter {
          $0.tab.plugin.hostID == host && !$0.closed && $0.connection != nil
        }
        guard !live.isEmpty else {
          self.clientWatch[host] = nil
          if self.tabs.values.contains(where: {
            $0.tab.plugin.hostID == host && !$0.closed && $0.connection != nil
          }) {
            self.ensureClientWatch(host: host)
          }
          return
        }
        guard let connection = live.first(where: { !$0.busy })?.connection else { continue }
        let epochs = Dictionary(uniqueKeysWithValues: live.map { ($0.tab.id, $0.clientEpoch) })
        let listed: String?
        if let output = try? await connection.execute(TmuxClients.listCommand) {
          listed = TmuxClients.listing(status: output.status, stdout: output.stdout, stderr: output.stderr)
        } else {
          listed = nil
        }
        guard !Task.isCancelled else { return }
        guard let listed else {
          pause = min(pause * 2, .seconds(15))
          continue
        }
        pause = .seconds(1)
        for tab in self.tabs.values {
          guard let epoch = epochs[tab.tab.id] else { continue }
          tab.noteClients(listed: listed, epoch: epoch)
        }
      }
    }
  }

  func remember(_ sessions: [TmuxSessionInfo], on host: UUID) {
    sessionsByHost[host] = sessions
  }

  func rememberedSessions(on host: UUID) -> [TmuxSessionInfo] {
    sessionsByHost[host] ?? []
  }

  func remember(_ panes: [(tty: String, session: String)], on host: UUID) {
    panesByHost[host] = panes
  }

  /// The pane Nerve named is this host's session. Focus the tab already
  /// showing it, or attach it on a shell that is still free. A pane list
  /// belongs to one saved host; its tabs say which machine that is, so a
  /// `/dev/pts/3` on another machine is never this one.
  public func claimTerminal(host: String, terminal: String) -> Bool {
    let wanted = PluginTerminalIdentity(host: host, terminal: terminal)
    let hits = panesByHost.flatMap { hostID, panes in
      guard let machine = machine(of: hostID) else { return [(UUID, String)]() }
      return panes.filter { PluginTerminalIdentity(host: machine, terminal: $0.tty).matches(wanted) }
        .map { (hostID, $0.session) }
    }
    guard hits.count == 1, let hit = hits.first else { return false }
    if let holder = tab(owning: hit.1, on: hit.0) {
      holder.tab.focus()
      return true
    }
    guard let shell = tabs.values.first(where: { $0.tab.plugin.hostID == hit.0 && !$0.closed }),
      let session = shell.listedSessions.first(where: { $0.id == hit.1 })
    else { return false }
    shell.tab.focus()
    shell.choose(session, windowID: nil)
    return true
  }

  /// The tab attached to this session, if any.
  ///
  /// By host as well as by ID: a session ID is `$0`, `$1`… counted by each
  /// tmux server, so every machine has a `$0` and they are not the same one.
  func tab(owning session: String, on host: UUID) -> TmuxTab? {
    tabs.values.first { $0.shellSessionID == session && $0.tab.plugin.hostID == host }
  }

  /// The machine a saved host's shells are on, from any of its live tabs.
  private func machine(of host: UUID) -> String? {
    tabs.values.lazy.filter { $0.tab.plugin.hostID == host && !$0.closed }
      .compactMap { $0.tab.terminalHost() }.first
  }

  public func settings() -> AnyView { AnyView(EmptyView()) }
}

/// Which neighbouring pane a focus command moves to, and the keys that ask
/// for it: h, j, k, l, as in vi and in tmux's own `select-pane` bindings.
enum TmuxPaneDirection: CaseIterable {
  case left, down, up, right

  var commandID: String {
    switch self {
    case .left: "focusLeft"
    case .down: "focusDown"
    case .up: "focusUp"
    case .right: "focusRight"
    }
  }

  var title: String {
    switch self {
    case .left: "Focus Pane Left"
    case .down: "Focus Pane Down"
    case .up: "Focus Pane Up"
    case .right: "Focus Pane Right"
    }
  }

  var symbol: String {
    switch self {
    case .left: "arrow.left.square"
    case .down: "arrow.down.square"
    case .up: "arrow.up.square"
    case .right: "arrow.right.square"
    }
  }

  var key: String {
    switch self {
    case .left: "h"
    case .down: "j"
    case .up: "k"
    case .right: "l"
    }
  }

  /// `select-pane`'s own flag for the direction.
  var flag: String {
    switch self {
    case .left: "-L"
    case .down: "-D"
    case .up: "-U"
    case .right: "-R"
    }
  }
}
