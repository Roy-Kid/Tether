import SwiftUI
import Tether
import TetherPluginKit

/// tmux, as a tab plugin: every terminal tab carries a menu. The session
/// itself is whatever tmux draws in that tab's ordinary terminal.
///
/// The plugin is where the tabs meet. It knows every tab it is attached to,
/// which is what "a session belongs to one tab" needs and what the host,
/// which does not know what a session is, could not answer.
@MainActor
public final class TmuxPlugin: TabPlugin {
  public static let id = "dev.tether.tmux"
  public let metadata = PluginMetadata(
    id: TmuxPlugin.id, name: "tmux", symbol: "rectangle.split.2x2",
    summary: "Persistent sessions, in the terminal itself.")
  /// Beside Files on a Mac: the host draws one status-bar button per inspector
  /// accessory. A phone has no status bar, so the shell button keeps the picker.
  public let accessory = TabAccessory(
    symbol: "rectangle.split.2x2", name: "tmux sessions",
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
  }
  private var tabs: [UUID: TmuxTab] = [:]

  public init() {}

  public func attach(to tab: TabContext) -> any TabAttachment {
    let id = tab.id
    let host = tab.plugin.hostID
    let attached = TmuxTab(
      tab: tab,
      owner: { [weak self] session in self?.tab(owning: session, on: host) },
      onClose: { [weak self] in self?.tabs[id] = nil })
    tabs[id] = attached
    return attached
  }

  /// The tab attached to this session, if any.
  ///
  /// By host as well as by ID: a session ID is `$0`, `$1`… counted by each
  /// tmux server, so every machine has a `$0` and they are not the same one.
  func tab(owning session: String, on host: UUID) -> TmuxTab? {
    tabs.values.first { $0.shellSessionID == session && $0.tab.plugin.hostID == host }
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
