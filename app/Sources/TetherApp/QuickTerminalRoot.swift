#if os(macOS)
  import AppKit
  import SwiftUI
  import TetherPluginKit
  import TetherUI

  /// What the quick terminal can be showing, decided from the shared
  /// TabSet alone. Terminal-only where a plugin's own view would be: a
  /// plugin's cached native view cannot appear in two hosts, so the panel
  /// offers the main window rather than drawing plugin content — the one
  /// bridge that still reveals it.
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
  }

  /// The quick terminal's content: the shared canvas, the shared tab
  /// strip, and the way back to the main window where a plugin's own
  /// views live. Regular workspace actions — new, close, reconnect,
  /// palette, host picker — run where they are asked: here, while the
  /// panel is the interaction's effective host. It does not disappear
  /// for them; only the plugin and Settings bridge reveals the main
  /// window.
  struct QuickTerminalRoot: View {
    @Bindable var tabs: TabSet
    let registry: PluginRegistry
    /// Weak: the controller owns the panel that hosts this view.
    weak var controller: QuickTerminalController?
    /// The one executor these tabs answer to; this panel is one of its
    /// hosts and says so through the reporter below.
    let interaction: WorkspaceInteraction
    @AppStorage(TetherUI.Palette.colorStyleKey) private var colorStyle = TetherUI.Palette.defaultColorStyle
    @AppStorage(WorkspaceAppearance.opacityKey) private var backgroundOpacity = WorkspaceAppearance.defaultOpacity
    /// The tab bar's place is the shared preference; the panel draws it
    /// where the workspace window would — a top strip, or a leading
    /// sidebar the same width both windows keep.
    @AppStorage(TabLayout.preferenceKey) private var tabLayout = TabLayout.default
    @AppStorage("workspace.tabSidebarWidth") private var tabSidebarWidth = Double(Chrome.tabSidebarIdeal)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// This panel's id in the shared interaction (`QuickTerminalController
    /// .panelID`), so the arbitration and this root agree even if the
    /// controller is somehow gone.
    @State private var fallbackID = UUID()

    private var panelID: UUID { controller?.panelID ?? fallbackID }

    /// Whether this host presents the shared presentations: a blocking
    /// question's fixed owner first, then the effective host.
    private var presents: Bool {
      (interaction.presentationOwner ?? interaction.effectiveHost) == panelID
    }

    /// The strip the workspace window's layout preference asks for, with
    /// the same handoffs: a plugin's own views stay on the main window.
    private var tabStrip: some View {
      WorkspaceTabBar(
        tabs: tabs, registry: registry, layout: tabLayout,
        leadingClearance: 0,
        onNewTab: { _ = interaction.dispatch(.newTab, from: panelID) },
        accessoryHandoff: { handAccessoryToMain() },
        performAction: { _ = interaction.dispatch($0, from: panelID) },
        onClose: { interaction.requestCloseFromTabBar($0, from: panelID) })
    }

    var body: some View {
      VStack(spacing: 0) {
        // The one chrome row is the shared tab strip; the quick terminal
        // adds no row of its own and no window controls.
        if tabs.showsTabBar(for: panelID) && tabLayout == .horizontal {
          tabStrip
        }
        HStack(spacing: 0) {
          if tabs.showsTabBar(for: panelID) && tabLayout == .vertical {
            SideColumn(side: .leading, width: $tabSidebarWidth,
                       range: Chrome.tabSidebarMin...Chrome.tabSidebarMax) {
              tabStrip
            }
          }
          content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
      }
      // `.fullSizeContentView` covers the titlebar region, but SwiftUI
      // still lays out under its safe-area inset: without this the strip
      // sits a titlebar-row lower, leaving an empty row that reads as a
      // title bar. The titlebar is transparent and buttonless; ignoring
      // the inset shows nothing but the panel. `WorkspaceView` agrees.
      .ignoresSafeArea(.container, edges: .top)
      .background { WorkspaceBackdrop() }
      .environment(\.workspaceBackgroundOpacity, opacity)
      .background {
        WorkspaceHostReporter(hostID: panelID, kind: .quick, interaction: interaction)
      }
      .background {
        // The same monitor the workspace windows run; the interaction
        // decides whether this host's chords answer now.
        WorkspaceKeyBindingMonitor(
          enabled: true, textEditingEnabled: true) {
          binding, repeated, editingText in
          routeShortcut(binding, repeated: repeated, editingText: editingText)
        }
        .allowsHitTesting(false)
      }
      .modifier(WorkspaceHostPresenters(
        tabs: tabs, interaction: interaction, hostID: panelID,
        store: interaction.store, registry: registry))
      .environment(\.isFrontWindow, presents)
      .environment(\.surfaceDrivesSize, interaction.drivesSurface(panelID))
    }

    private var opacity: Double {
      WorkspaceAppearance.opacity(
        theme: colorStyle, stored: backgroundOpacity,
        reduceTransparency: reduceTransparency, contrast: contrast)
    }

    @ViewBuilder
    private var content: some View {
      switch QuickPresentation.presentation(for: tabs) {
      case .terminal:
        WorkspaceCanvas(
          tabs: tabs, interaction: interaction,
          inputAllowed: interaction.inputAllowed(in: panelID),
          claimsDialogs: presents,
          rendersPluginContent: false, passive: true,
          placeholder: AnyView(
            VStack(spacing: UIStyle.Space.group) {
              QuietMark("No Open Terminals", systemImage: "terminal")
              Button("Show in Main Window") { revealMain() }
            }))
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

    /// The main window takes over — the one bridge left: a plugin's own
    /// views and Settings live there. Regular workspace actions never
    /// call this; they run here through the interaction. The panel's
    /// disappearance is the native bridge's report; nothing here fakes
    /// host state.
    private func revealMain() {
      DispatchQueue.main.async { [weak controller] in controller?.showAsMainWindow() }
    }

    /// An accessory click from the panel's strip belongs to the main
    /// window's strip: the panel opens nothing of the plugin itself —
    /// it opens the accessory there, once, and comes forward.
    private func handAccessoryToMain() {
      guard let tab = tabs.current,
        let picker = tabs.accessories.first(where: { $0.accessory.placement == .popover }),
        tab.canOpen(picker.id)
      else {
        return revealMain()
      }
      _ = interaction.showAccessory(picker.id, on: tab.id, from: panelID)
    }

    /// The panel's share of the workspace chords, through the one
    /// executor. The interaction decides whether this host answers: it
    /// does while the panel is effective; otherwise the chord waits for
    /// the host that is. Unified KeyBindingStore chords, IME-marked text
    /// and text fields behave exactly as in the workspace windows
    /// (`RootView`'s monitor).
    private func routeShortcut(_ binding: KeyBinding, repeated: Bool, editingText: Bool) -> Bool {
      handleWorkspaceShortcut(binding, repeated: repeated, editingText: editingText,
        interaction: interaction, hostID: panelID, registry: registry)
    }
  }
#endif
