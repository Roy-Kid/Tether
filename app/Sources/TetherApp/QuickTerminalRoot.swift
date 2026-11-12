#if os(macOS)
  import AppKit
  import SwiftUI
  import TetherPluginKit
  import TetherUI

  /// What the quick terminal can be showing, decided from the shared
  /// TabSet alone. Terminal-only by contract: when the selection is a
  /// plugin workspace page, or a tab whose shell a plugin stands in for,
  /// the panel offers the main window rather than drawing plugin content
  /// — a plugin's cached web view cannot appear in two hosts.
  enum QuickPresentation: Equatable {
    /// The selected tab's terminal, by id.
    case terminal(SessionTab.ID)
    /// The selected tab's shell is stood in for by a plugin attachment.
    case pluginContent
    /// The selection is a plugin workspace page.
    case pluginWorkspace
    /// Nothing is selected.
    case empty

    @MainActor
    static func presentation(for tabs: TabSet) -> QuickPresentation {
      guard let id = tabs.selected else { return .empty }
      if tabs.extensions.contains(where: { $0.id == id }) { return .pluginWorkspace }
      guard let tab = tabs.tabs.first(where: { $0.id == id }) else { return .empty }
      if tab.shown != nil { return .pluginContent }
      return .terminal(id)
    }

    /// The label of the offer bar for a tab the quick cannot answer for
    /// on its own: a question that is asked on the workspace window,
    /// which may be hidden or on another Space. Nil while the terminal
    /// runs or is still connecting — background output never summons
    /// anything, and neither does a stage change the person did not ask
    /// about.
    @MainActor
    static func mainWindowOffer(for tab: SessionTab) -> String? {
      if case .asking = tab.stage { return "Answer in the Main Window" }
      if tab.problemRaised { return "Answer in the Main Window" }
      if tab.isDisconnected { return "Reconnect in the Main Window" }
      return nil
    }
  }

  /// The quick terminal's content: the selected terminal, nothing else.
  /// No plugin panes, no palettes, no pickers, no dialogs, no session
  /// startup — the shared TabSet's sessions, selection, history and
  /// connection questions all belong to the main window's root. This root
  /// only renders what is selected; a secondary presenter here would
  /// either duplicate a question or cancel a shared one by disappearing.
  ///
  /// What the quick does beyond typing: it answers selection chords
  /// itself (previous/next terminal and tab move the shared selection),
  /// and hands everything that needs the main window's presenters —
  /// a new tab, a reconnect, a host switch — to the main window by
  /// revealing it and performing the action there, once.
  struct QuickTerminalRoot: View {
    @Bindable var tabs: TabSet
    let registry: PluginRegistry
    /// Weak: the controller owns the panel that hosts this view.
    weak var controller: QuickTerminalController?
    @AppStorage(TetherUI.Palette.colorStyleKey) private var colorStyle = TetherUI.Palette.defaultColorStyle
    @AppStorage(WorkspaceAppearance.opacityKey) private var backgroundOpacity = WorkspaceAppearance.defaultOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// This panel's id in the shared window arbitration
    /// (`QuickTerminalController.panelID`), so the arbitration and this
    /// root agree even if the controller is somehow gone.
    @State private var fallbackID = UUID()

    private var panelID: UUID { controller?.panelID ?? fallbackID }

    var body: some View {
      VStack(spacing: 0) {
        // The strip the window is dragged and double-clicked by.
        WindowDragArea()
          .frame(height: Chrome.titlebar)
          .background { WorkspaceMaterial() }
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      }
      .background { WorkspaceBackdrop() }
      .environment(\.workspaceBackgroundOpacity, opacity)
      .background {
        WindowState { value in
          tabs.note(window: panelID, shown: value.shown, key: value.key)
          // While the panel holds the key the workspace menu chords have
          // no window to act on: the menus stay disabled rather than fire
          // into a root that does not consume intents.
          if value.key { tabs.menuShortcuts = nil }
        }
        .allowsHitTesting(false)
      }
      .background {
        // The same monitor the workspace windows run, so customized
        // chords keep their meaning here — enabled only while the main
        // window's own gate says the window is free of blocking
        // questions (`TabSet.mainWindowShortcutsAllowed`). Selection
        // chords are answered in the panel; chords that need the main
        // window's presenters reveal it and hand the action over, once.
        WorkspaceKeyBindingMonitor(enabled: tabs.mainWindowShortcutsAllowed, textEditingEnabled: true) {
          binding, repeated, editingText in
          routeShortcut(binding, repeated: repeated, editingText: editingText)
        }
        .allowsHitTesting(false)
      }
      .environment(\.isFrontWindow, tabs.isFront(panelID))
    }

    private var opacity: Double {
      WorkspaceAppearance.opacity(
        theme: colorStyle, stored: backgroundOpacity,
        reduceTransparency: reduceTransparency, contrast: contrast)
    }

    @ViewBuilder
    private var content: some View {
      switch QuickPresentation.presentation(for: tabs) {
      case .terminal(let id):
        if let tab = tabs.tabs.first(where: { $0.id == id }) {
          terminal(tab)
        }
      case .pluginContent, .pluginWorkspace:
        VStack(spacing: UIStyle.Space.group) {
          QuietMark("Shown in the Main Window", systemImage: "rectangle.on.rectangle")
          Button("Show in Main Window") { revealMain() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .empty:
        VStack(spacing: UIStyle.Space.group) {
          QuietMark("No Open Terminals", systemImage: "terminal")
          Button("Show in Main Window") { revealMain() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }

    /// One selected terminal. Whole frames, no damage acknowledgment
    /// (`SessionView.passive`) — the main window's surface remains the
    /// one incremental consumer. While a question the main window owns
    /// is pending, the terminal takes no input and the panel offers the
    /// way to it; a down tab answers its first key by revealing the main
    /// window, where its question is asked once.
    private func terminal(_ tab: SessionTab) -> some View {
      ZStack(alignment: .bottom) {
        SessionView(
          tab: tab,
          active: inputAllowed(tab),
          passive: true,
          onUnavailableInput: {
            revealMain()
            tab.raiseProblem()
          })
          .terminalInputEnabled(inputAllowed(tab))
          .id(tab.id)
        if let offer = offer(for: tab) {
          Button(offer) { revealMain() }
            .padding(UIStyle.Space.group)
            .background { WorkspaceMaterial() }
        }
      }
    }

    /// The offer bar, when there is one: the tab's own question, or —
    /// read from the main window's published gate — a question the main
    /// window holds that the terminal here must not act behind.
    private func offer(for tab: SessionTab) -> String? {
      if !tabs.mainWindowInputAllowed { return "Answer in the Main Window" }
      return QuickPresentation.mainWindowOffer(for: tab)
    }

    /// A pending question the main window presents: the terminal takes
    /// no input behind it. A down tab whose question has not been raised
    /// still takes input — its first key reveals the main window and
    /// raises the question there.
    private func inputAllowed(_ tab: SessionTab) -> Bool {
      guard tabs.mainWindowInputAllowed else { return false }
      if case .asking = tab.stage { return false }
      return !tab.problemRaised
    }

    /// The main window takes over: the panel leaves the front
    /// arbitration first, so an intent this action performs lands on the
    /// window now in front — delivered exactly once, never stranded on a
    /// root that does not consume it. The reveal itself runs on the next
    /// turn: activation does not belong inside a key event.
    private func revealMain(perform action: WorkspaceAction? = nil) {
      tabs.note(window: panelID, shown: false, key: false)
      if let action { tabs.perform(action) }
      DispatchQueue.main.async { [weak controller] in controller?.showAsMainWindow() }
    }

    /// The panel's share of the workspace chords: selection moves stay
    /// here, everything else is handed to the main window. Unified
    /// KeyBindingStore chords, IME-marked text and text fields behave
    /// exactly as in the workspace windows (`RootView`'s monitor).
    private func routeShortcut(_ binding: KeyBinding, repeated: Bool, editingText: Bool) -> Bool {
      let definitions = KeyBindingCatalog.commands(registry: registry, tabs: tabs)
      guard let id = tabs.keyBindings.command(for: binding, in: definitions, offered: tabs.offeredCommandIDs),
        !editingText || WorkspaceAction.answersWhileEditingText(id)
      else { return false }
      // Plugin and other non-workspace commands are not ours to run or to
      // swallow: the event goes on to the handling it would find anywhere
      // else. Only workspace actions are routed here.
      guard let action = WorkspaceAction(rawValue: id) else { return false }
      guard !repeated else { return true }
      switch action {
      case .previousTerminal, .nextTerminal, .previousTab, .nextTab:
        tabs.perform(action)
      default:
        revealMain(perform: action)
      }
      return true
    }
  }
#endif
