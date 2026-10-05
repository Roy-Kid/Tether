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
  public let accessory = TabAccessory(symbol: "rectangle.split.2x2", name: "tmux sessions")
  public let commandDescriptors = [
    PluginCommandDescriptor(id: "detach", title: "Detach Session"),
    PluginCommandDescriptor(id: "newWindow", title: "New Window"),
    PluginCommandDescriptor(id: "splitHorizontal", title: "Split Left and Right"),
    PluginCommandDescriptor(id: "splitVertical", title: "Split Top and Bottom"),
    PluginCommandDescriptor(id: "zoom", title: "Zoom Pane"),
  ]
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
