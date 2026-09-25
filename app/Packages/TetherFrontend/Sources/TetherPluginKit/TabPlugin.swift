import SwiftUI
import Tether

/// A plugin that works inside a terminal tab rather than beside it.
///
/// A `PluginWorkspace` is a tab of its own. This is the other shape: the
/// plugin hangs off a terminal tab the host already has — an accessory on the
/// tab, a picker behind it, and content that can stand in for the tab's shell
/// while the tab stays the same tab. tmux is the first; it is not the last
/// thing that will want to show something other than the shell it was
/// reached through.
///
/// The host never names the plugin. It asks each tab plugin for its
/// accessory, asks the tab's attachment what to draw, and forwards the tab's
/// lifetime. Everything else — what the picker lists, which tab owns what —
/// is the plugin's.
@MainActor
public protocol TabPlugin: TetherPlugin {
  /// What every terminal tab carries for this plugin.
  var accessory: TabAccessory { get }
  /// Called once per tab, the first time the accessory opens there, and only
  /// once the tab has a connection to lease.
  func attach(to tab: TabContext) -> any TabAttachment
}

extension TabPlugin {
  /// A tab plugin is launched by opening its accessory on the current tab;
  /// the host does that, and there is no workspace to open.
  public func launch(in context: PluginContext) {}
}

/// An icon on a terminal tab. The name is its tooltip and its menu item: the
/// window says nothing in words (law: app-ui-chrome).
public struct TabAccessory: Sendable {
  /// Where the host draws what is behind the accessory.
  public enum Placement: Sendable, Equatable {
    /// Something to choose from, dismissed once chosen: a popover on a Mac.
    /// The attachment's `accessoryContent()`.
    case popover
    /// Something kept open beside the terminal while it runs: the window's
    /// inspector on a Mac. The attachment's `inspector()`.
    case inspector
  }

  public let symbol: String
  public let name: String
  /// A phone has no inspector and no popover; either placement opens a
  /// sheet there, with the same content.
  public let placement: Placement

  public init(symbol: String, name: String, placement: Placement = .popover) {
    self.symbol = symbol
    self.name = name
    self.placement = placement
  }
}

/// One terminal tab, as a plugin attached to it sees it.
@MainActor
public struct TabContext {
  /// The tab's identity. Stable for the tab's life; never shown.
  public let id: UUID
  /// The tab's lease and host, the same shape a workspace plugin is given.
  public let plugin: PluginContext
  /// The local shell's controlling tty, if the producer exposes one.
  public let terminalName: String?
  /// Brings this tab to the front.
  public let focus: () -> Void
  /// Closes this plugin's accessory, wherever the host drew it.
  public let dismissAccessory: () -> Void
  /// Presents a sheet over the window.
  ///
  /// Through the host, because who can present differs by platform: a Mac's
  /// accessory is a popover and the window presents over it; a phone's is a
  /// sheet already, and only that sheet can present a second one.
  public let present: (AnyView) -> Void
  public let dismissSheet: () -> Void
  /// Types `text` at this tab's prompt, as a paste: the person still presses
  /// return. The host owns the terminal; a plugin never writes to it.
  public let insertText: (String) -> Void
  /// The directory the tab's shell last reported, if it reports one. What
  /// a relative path printed in the terminal is most likely relative to.
  public let workingDirectory: () -> String?
  /// Brings this plugin's accessory up on this tab, if it is not already —
  /// to show something the person asked for from the terminal.
  public let showAccessory: () -> Void
  /// Everything the tab's plugins offer for a link, combined the way the
  /// host's own terminal combines them. For a plugin that draws a terminal
  /// of its own — tmux's panes — so pointing there works as it does in the
  /// shell, without the plugin knowing who answers.
  public let linkActions: (PointedLink) -> LinkActions?

  public init(
    id: UUID, plugin: PluginContext, terminalName: String? = nil,
    focus: @escaping () -> Void, dismissAccessory: @escaping () -> Void,
    present: @escaping (AnyView) -> Void, dismissSheet: @escaping () -> Void,
    insertText: @escaping (String) -> Void = { _ in },
    workingDirectory: @escaping () -> String? = { nil },
    showAccessory: @escaping () -> Void = {},
    linkActions: @escaping (PointedLink) -> LinkActions? = { _ in nil }
  ) {
    self.id = id
    self.plugin = plugin
    self.terminalName = terminalName
    self.focus = focus
    self.dismissAccessory = dismissAccessory
    self.present = present
    self.dismissSheet = dismissSheet
    self.insertText = insertText
    self.workingDirectory = workingDirectory
    self.showAccessory = showAccessory
    self.linkActions = linkActions
  }
}

/// Something a person pointed at in a terminal, and how to learn where the
/// program that printed it was.
public struct PointedLink {
  public let link: TerminalLink
  /// The directory a relative path is most likely relative to: what the
  /// shell reported, or where tmux says a pane is. Asked only when needed,
  /// because for a pane it is a round trip.
  public let directory: @MainActor () async -> String?

  public init(link: TerminalLink, directory: @escaping @MainActor () async -> String?) {
    self.link = link
    self.directory = directory
  }
}

/// What a tab plugin offers for something a person pointed at in the
/// terminal: a path an agent printed, a hyperlink a program attached.
public struct LinkActions {
  /// ⌘-click or a force click on a Mac, tapping the preview on a phone:
  /// look at it now.
  public let open: (() -> Void)?
  /// A picture of it for a phone's long-press. Loads itself.
  public let preview: (() -> AnyView)?
  /// For the menu a right-click or a long-press opens. Words: it is a menu.
  public let commands: [PluginCommand]
  /// Whether what it names is really there. Hovering underlines a link only
  /// once this says yes, so text that merely looks like a path is left
  /// alone. `nil` when there is nothing to check.
  public let exists: (@MainActor () async -> Bool)?

  public init(
    open: (() -> Void)? = nil, preview: (() -> AnyView)? = nil, commands: [PluginCommand] = [],
    exists: (@MainActor () async -> Bool)? = nil
  ) {
    self.open = open
    self.preview = preview
    self.commands = commands
    self.exists = exists
  }
}

/// What a tab plugin keeps on one tab. The host holds it for the tab's life
/// and closes it with the tab.
@MainActor
public protocol TabAttachment: AnyObject {
  /// Whether this stands in for the tab's shell right now. The shell is not
  /// gone while it does; choosing it again is the plugin's to offer.
  var isShowing: Bool { get }
  /// Beside the tab's name while showing.
  var subtitle: String { get }
  /// What is showing lost its connection. The host words it, once, in its
  /// own status bar.
  var isDisconnected: Bool { get }
  /// One line under the tab's close confirmation, when closing leaves
  /// something behind a person would otherwise wonder about.
  var closeNote: String? { get }
  /// For the menu bar and the palette, under the plugin's name.
  var commands: [PluginCommand] { get }
  /// Drawn in place of the shell while `isShowing`.
  func content() -> AnyView
  func inspector() -> AnyView
  /// Behind the tab's accessory: a popover on a Mac, a sheet on a phone.
  func accessoryContent() -> AnyView
  /// The tab's lease was replaced, as after a reconnect.
  func connectionChanged(_ connection: RemoteConnection)
  /// The tab closed, or the plugin was turned off.
  func close()
  /// Files from this machine were dropped on the tab. `true` takes them;
  /// the host offers them to each attachment in turn and stops at the first
  /// that does.
  func receive(files: [URL]) -> Bool
  /// What this offers for a link pointed at in the tab's terminal, or `nil`
  /// for nothing. Asked when a person points, and answered at once: anything
  /// slow — checking the path exists — happens inside the actions.
  func actions(for pointed: PointedLink) -> LinkActions?
}

extension TabAttachment {
  public func receive(files: [URL]) -> Bool { false }
  public func actions(for pointed: PointedLink) -> LinkActions? { nil }
}
