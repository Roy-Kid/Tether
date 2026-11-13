import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif
import Tether
import TetherPluginHost
import TetherPluginKit
import TetherUI

/// What the system posts on the way out.
private let terminationNotification: Notification.Name = {
  #if os(macOS)
    NSApplication.willTerminateNotification
  #else
    UIApplication.willTerminateNotification
  #endif
}()

#if os(iOS)
  /// One status plugin's panel, opened from its lamp. The id is the plugin's,
  /// so opening the same lamp again is the same page.
  private struct PhoneStatusPanel: Identifiable {
    let pluginID: String
    let workspace: any PluginWorkspace
    var id: String { pluginID }
  }
#endif

struct RootView: View {
  @Bindable var store: HostStore
  @Bindable var tabs: TabSet
  let registry: PluginRegistry
  let secrets: any SecretStore
  let plugins: PluginAPI
  @Binding var installedPlugins: InstalledPlugins?
  /// The one executor these tabs answer to. Business — opening, splits,
  /// reconnects, passwords, notices, plugins — runs there; this view
  /// draws what the shared TabSet reports.
  let interaction: WorkspaceInteraction
  /// Where hosts are managed: Settings, opened at that page.
  @State private var route = SettingsRoute.shared
  @State private var visibility: NavigationSplitViewVisibility = .all
  @State private var showingSettings = false
  @AppStorage("appearance") private var appearance = "system"
  #if os(macOS)
    @AppStorage(TetherUI.Palette.colorStyleKey) private var theme = TetherUI.Palette.defaultColorStyle
    @AppStorage(WorkspaceAppearance.opacityKey) private var backgroundOpacity = WorkspaceAppearance.defaultOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
  #endif
  @AppStorage(TabLayout.preferenceKey) private var tabLayout = TabLayout.default
  #if os(macOS)
    @AppStorage("workspace.inspectorWidth") private var inspectorWidth = Double(Chrome.inspectorIdeal)
    @AppStorage("workspace.tabSidebarWidth") private var tabSidebarWidth = Double(Chrome.tabSidebarIdeal)
  #endif
  @Environment(\.openURL) private var openURL
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif
  @Environment(\.workspaceIsPrimary) private var isPrimaryWindow
  /// The workspace host's stable id on both platforms, not a new one per view.
  private var windowID: UUID { interaction.workspaceHostID }
  #if os(iOS)
    @Environment(\.scenePhase) private var phase
  #endif
  #if os(iOS)
    /// The window's width. A large phone turned sideways is regular here;
    /// the phone still uses the portrait stack (`TouchLayout`).
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Compact on a phone turned sideways, where every row counts.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The column a collapsed split view shows. Follows the selection, the
    /// way the stack it replaced pushed and popped with it.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    /// Whether the on-screen keyboard is up.
    @State private var keyboardShown = false
    /// The status plugin opened from its lamp. One page, the same cover as any other plugin.
    @State private var statusPanel: PhoneStatusPanel?
    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
  #endif

  private var extensionWorkspace: (any PluginWorkspace)? {
    tabs.extensions.first { $0.id == tabs.selected }?.workspace
  }
  private var pluginStatusItems: [PluginStatusBarItem] {
    registry.plugins.filter { registry.isEnabled($0.metadata.id) }.compactMap(\.statusBarItem)
  }

  /// A password for a tab that does not exist yet blocks the window. One for
  /// a terminal already on screen covers only that terminal.
  private var connectBlocksWindow: Bool {
    #if os(macOS)
      // A reconnect question covers its terminal. History still belongs to
      // the window, and so does a password for a connection with no terminal.
      interaction.connectRequests.contains { !$0.coversTerminal }
    #else
      !interaction.connectRequests.isEmpty
    #endif
  }

  private var terminalInputAllowed: Bool {
    #if os(macOS)
      interaction.inputAllowed(in: windowID) && !connectBlocksWindow
    #else
      interaction.inputAllowed(in: windowID) && !connectBlocksWindow && statusPanel == nil
    #endif
  }
  var body: some View {
    windowChrome
      .onAppear {
        tabs.onEmptied = { LastTabPreference.quitIfChosen() }
        #if os(iOS)
          // One workspace host on the phone, on the same controller the
          // Mac's hosts use; the scene phase is its window state.
          interaction.register(id: windowID, kind: .workspace)
          updateScenePhase(phase)
        #endif
      }
      #if os(iOS)
        .onChange(of: phase) { _, phase in
          updateScenePhase(phase)
        }
      #endif
  }

  #if os(iOS)
    private func updateScenePhase(_ phase: ScenePhase) {
      interaction.update(id: windowID, state: WorkspaceHostState(
        orderedIn: phase != .background,
        renderVisible: phase == .active,
        keyWithinHost: phase == .active))
    }
  #endif

  @ViewBuilder
  private var container: some View {
    #if os(macOS)
      macWorkspace
    #else
      splitView
    #endif
  }

  #if os(macOS)
    private var macWorkspace: some View {
      let opacity = WorkspaceAppearance.opacity(theme: theme, stored: backgroundOpacity,
        reduceTransparency: reduceTransparency, contrast: contrast)
      return ZStack(alignment: .bottomLeading) {
        VStack(spacing: 0) {
          if tabs.showsTabBar(for: windowID) && tabLayout == .horizontal {
            WorkspaceTabBar(
              tabs: tabs, registry: registry,
              onNewTab: { _ = interaction.dispatch(.newTab, from: windowID) },
              performAction: { _ = interaction.dispatch($0, from: windowID) },
              onClose: { interaction.requestCloseFromTabBar($0, from: windowID) })
            // One strip for every terminal on this host, above every pane. A
            // split used to be a system split view that drew over this row.
            .layoutPriority(1)
            .zIndex(1)
          } else {
            HStack(spacing: 0) {
              Color.clear.frame(width: Chrome.trafficLights)
              Color.clear.background { WindowDragArea() }
            }
            .frame(height: tabs.zen ? Chrome.titlebar : Chrome.tab)
            .background { WorkspaceMaterial() }
          }
          // Side columns keep their width; the window's changes go to the
          // canvas alone (`SideColumn`).
          HStack(spacing: 0) {
            if tabs.showsTabBar(for: windowID) && tabLayout == .vertical {
              SideColumn(side: .leading, width: $tabSidebarWidth,
                         range: Chrome.tabSidebarMin...Chrome.tabSidebarMax) {
                WorkspaceTabBar(tabs: tabs, registry: registry, layout: .vertical,
                  onNewTab: { _ = interaction.dispatch(.newTab, from: windowID) },
                  performAction: { _ = interaction.dispatch($0, from: windowID) },
                  onClose: { interaction.requestCloseFromTabBar($0, from: windowID) })
              }
            }
            WorkspaceCanvas(
              tabs: tabs, interaction: interaction,
              inputAllowed: terminalInputAllowed,
              claimsDialogs: presentsDialogs,
              rendersPluginContent: true, passive: false,
              placeholder: AnyView(canvasPlaceholder))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .clipped()
            // The inspector sits under the tab strip, not beside it in the
            // titlebar: its own header belongs to the column, in the same
            // row as the listing it controls (design 16-inspector).
            if showInspector {
              SideColumn(side: .trailing, width: $inspectorWidth,
                         range: Chrome.inspectorMin...Chrome.inspectorMax) {
                inspectorPane
                  .scrollContentBackground(opacity < 1 ? .hidden : .automatic)
                  .frame(maxHeight: .infinity)
                  .background { WorkspaceMaterial() }
              }
            }
          }
          if !tabs.zen {
            HostStatusBar(
              tabs: tabs,
              store: store,
              pluginStatusItems: pluginStatusItems,
              statusBarLabel: { pluginID in
                registry.plugins.first { $0.metadata.id == pluginID }?.statusBarLabel()
              },
              statusBarSettings: { pluginID in
                registry.plugins.first { $0.metadata.id == pluginID }?.statusBarSettings()
              },
              makeStatusWorkspace: { pluginID in
                registry.plugins.first { $0.metadata.id == pluginID }?.statusBarWorkspace()
              })
              .layoutPriority(1)
          }
        }
      }
      .background { WorkspaceBackdrop() }
      .background { CompactTitlebar(closeRequests: tabs.windowCloseRequests) }
      .environment(\.workspaceBackgroundOpacity, opacity)
      .ignoresSafeArea(.container, edges: .top)
      .onChange(of: tabLayout) { _, _ in
        tabs.accessory = nil
        tabs.tabMenu = nil
      }
    }

    /// Whether this host presents the workspace's shared presentations:
    /// the blocking question's fixed owner first, then the effective host.
    private var presentsDialogs: Bool {
      (interaction.presentationOwner ?? interaction.effectiveHost) == windowID
    }

    /// What the canvas fills itself with when nothing is selected.
    private var canvasPlaceholder: some View {
      EmptyWorkspace()
        .padding(Chrome.margin)
    }

    private var showInspector: Bool {
      tabs.inspector && !tabs.zen
    }

  #endif

  #if os(iOS)
    /// Two columns where there is room for two, one at a time where there
    /// is not — the same split view either way.
    ///
    /// A stack on a phone and a split view on an iPad was two layouts, and
    /// turning the device or resizing the window swapped one for the other,
    /// rebuilding every view under it: the terminal, and its keyboard with it.
    ///
    /// Collapsed, a split view pushes its detail only when a `NavigationLink`
    /// is followed, and nothing here is a link — opening a host goes through a
    /// question first — so the column it shows follows the selection instead.
    ///
    /// A phone stays collapsed in landscape too. Its landscape width is
    /// regular, which would otherwise leave the host list beside the terminal.
    private var splitView: some View {
      NavigationSplitView(columnVisibility: columnVisibility, preferredCompactColumn: compactColumnChoice) {
        sidebar
      } detail: {
        phoneDetail
      }
      .navigationSplitViewStyle(.balanced)
      .modifier(PhoneColumnStyle(phone: phone))
      .fullScreenCover(item: $statusPanel) { panel in
        statusCover(panel)
      }
      .onReceive(NotificationCenter.default.publisher(for: .closePluginPanel)) { _ in
        closeStatus()
      }
      .onReceive(NotificationCenter.default.publisher(for: .openPluginPanel)) { note in
        openReturned(PluginOpen.id(from: note))
      }
      .onChange(of: tabs.selected, initial: true) { _, id in
        compactColumn = id == nil ? .sidebar : .detail
      }
      .onChange(of: [sizeClass, verticalSizeClass], initial: true) { _, _ in
        tabs.wide = TouchLayout.wide(
          phone: phone, regularWidth: sizeClass == .regular, regularHeight: verticalSizeClass == .regular)
      }
      // There is no floating host picker here: the host list is the sidebar,
      // so asking for the picker — ⌘⇧H, or a new terminal with nowhere to
      // open it — shows that instead of an invisible panel holding the keys.
      .onChange(of: tabs.hostPicker) { _, asked in
        guard asked else { return }
        tabs.hostPicker = false
        if TouchLayout.popsToHostList(phone: phone, compactWidth: sizeClass == .compact) {
          tabs.selected = nil
        } else {
          visibility = .all
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
        keyboardShown = true
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
        keyboardShown = false
      }
    }

    /// Going back on a phone leaves the terminal running and no longer in
    /// front, as popping the stack did. Landscape is the same stack.
    private var compactColumnChoice: Binding<NavigationSplitViewColumn> {
      Binding(
        get: { compactColumn },
        set: { column in
          compactColumn = column
          if column == .sidebar,
            TouchLayout.popsToHostList(phone: phone, compactWidth: sizeClass == .compact)
          {
            tabs.selected = nil
          }
        })
    }

    /// The host list steps aside while the terminal is immersive, and comes
    /// back as it was.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
      Binding(
        get: { immersive ? .detailOnly : visibility },
        set: { if !immersive { visibility = $0 } })
    }

    /// A phone on its side with the keyboard up has a handful of rows left,
    /// and the navigation bar would take two of them. The bar gives its
    /// height to the terminal until the keyboard goes down — the keyboard's
    /// own dismiss key — and then comes back, with the way back on it.
    private var immersive: Bool {
      verticalSizeClass == .compact && keyboardShown && tabs.current != nil
    }

    private var inspectorShown: Binding<Bool> {
      Binding(
        get: { tabs.inspector && tabs.wide },
        // Narrowing the window takes the column away without forgetting it
        // was open.
        set: { if tabs.wide { tabs.inspector = $0 } })
    }
  #endif

  #if os(iOS)
    /// Collapses the phone's split view onto the portrait stack.
    ///
    /// The environment is what SwiftUI's columns read. The trait override is
    /// what `UISplitViewController` reads after a rotation, which otherwise
    /// puts the regular landscape width back and shows the host list again.
    private struct PhoneColumnStyle: ViewModifier {
      let phone: Bool

      @ViewBuilder
      func body(content: Content) -> some View {
        if phone {
          content
            .environment(\.horizontalSizeClass, .compact)
            .background { PhoneStackTraits().allowsHitTesting(false) }
        } else {
          content
        }
      }
    }

    private struct PhoneStackTraits: UIViewControllerRepresentable {
      func makeUIViewController(context: Context) -> TraitController {
        let controller = TraitController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
      }

      func updateUIViewController(_ controller: TraitController, context: Context) {
        controller.collapseIfPhone()
      }

      final class TraitController: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
          super.didMove(toParent: parent)
          collapseIfPhone()
        }

        override func viewWillAppear(_ animated: Bool) {
          super.viewWillAppear(animated)
          collapseIfPhone()
        }

        override func viewDidAppear(_ animated: Bool) {
          super.viewDidAppear(animated)
          collapseIfPhone()
        }

        override func viewWillTransition(
          to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
        ) {
          super.viewWillTransition(to: size, with: coordinator)
          coordinator.animate(alongsideTransition: nil) { _ in self.collapseIfPhone() }
        }

        func collapseIfPhone() {
          guard UIDevice.current.userInterfaceIdiom == .phone, let split = splitViewController else { return }
          // The override has to land on the split's parent. On the split
          // itself it only reaches the columns, and the split keeps the
          // landscape width it was given. Writing the same value again
          // invalidates layout, so stop once it is installed.
          let host = split.parent ?? split
          guard host.traitOverrides.horizontalSizeClass != .compact else { return }
          host.traitOverrides.horizontalSizeClass = .compact
        }
      }
    }
  #endif

  private var sidebar: some View {
    Sidebar(
      store: store,
      onOpen: { interaction.open($0) }, onEdit: { route.show(.edit($0.id)) }, onNew: { route.show(.newHost) },
      onSettings: { showingSettings = true }
    )
    .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
    #if os(iOS)
      // The detail bar is off-screen while a phone is on the host list.
      // An iPad shows both columns, so the lamps stay on the detail only.
      .toolbar {
        if phone && compactColumn == .sidebar {
          ToolbarItemGroup(placement: .topBarLeading) {
            statusLamps
          }
        }
      }
    #endif
  }


  /// The window's second column, where there is a window to put one in:
  /// a Mac's, or an iPad's at full width.
  private var inspectorPane: some View {
    Group {
      if let workspace = extensionWorkspace {
        workspace.inspector()
      } else if let pluginID = tabs.inspectorPlugin,
        let tab = tabs.current,
        let attachment = tab.attachment(for: pluginID)
      {
        // This tab's inspector. Without an identity SwiftUI keeps the previous
        // tab's view, so a shell beside a client never loads that host's list.
        attachment.inspector().id(tab.id)
      } else if let shown = tabs.current?.shown {
        shown.inspector()
      } else if let tab = tabs.current {
        Form {
          Section("Connection") {
            LabeledContent("Host", value: tab.host.hostname)
            LabeledContent("User", value: tab.host.username)
            LabeledContent("Port", value: String(tab.host.port))
            LabeledContent("Status", value: tab.stateName)
          }
        }.formStyle(.grouped)
      } else {
        QuietMark("No workspace selected", systemImage: "sidebar.right")
      }
    }
  }

  /// What a touch screen shows beside the host list: one terminal, or one
  /// plugin workspace, at a time.
  ///
  /// Not a tab bar. A tab bar is a handful of fixed sections; terminals are
  /// documents, as many as a person opens, all drawn with the same icon and
  /// spilling into "More" at the sixth. They are switched from the title.
  private var phoneDetail: some View {
    Group {
      if let entry = tabs.extensions.first(where: { $0.id == tabs.selected }) {
        extensionContent(entry)
      } else if let tab = tabs.current ?? tabs.visibleTabs.first {
        phoneSession(tab)
      } else if let entry = tabs.extensions.first {
        extensionContent(entry)
      } else {
        EmptyWorkspace()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(extensionWorkspace?.title ?? tabs.current?.title ?? "Tether")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .modifier(TerminalTitleMenu(shown: !tabs.terminalChoices.isEmpty) { terminalSwitcher })
      .toolbarVisibility(immersive ? .hidden : .automatic, for: .navigationBar)
      .inspector(isPresented: inspectorShown) {
        inspectorPane
          .inspectorColumnWidth(min: Chrome.inspectorMin, ideal: Chrome.inspectorIdeal, max: Chrome.inspectorMax)
      }
    #endif
    // Where this terminal is, what it can do, and closing it. The
    // connection's host, user and port are the inspector's, where there is
    // room for one; the host row in the sidebar carries them otherwise.
    .toolbar {
      #if os(iOS)
        ToolbarItemGroup(placement: .topBarLeading) {
          statusLamps
        }
      #endif
      ToolbarItemGroup(placement: .primaryAction) {
        #if os(iOS)
          Menu {
            if !tabs.wide { foldedAccessories }
            ForEach(Array(TouchCommands.sections(wide: tabs.wide).enumerated()), id: \.offset) { _, section in
              Section {
                ForEach(section, id: \.self) { action in
                  Button(tabs.title(for: action)) { _ = interaction.dispatch(action, from: windowID) }
                    .disabled(!tabs.canPerform(action))
                }
              }
            }
            if !tabs.wide, let id = tabs.selected {
              Section {
                Button(role: .destructive) {
                  tabs.requestClose(id)
                } label: {
                  Label("Close", systemImage: "xmark")
                }
              }
            }
          } label: {
            Label("Commands", systemImage: "ellipsis.circle")
          }
          .buttonStyle(.iconOnly)
          .accessibilityLabel("Commands")
          Button {
            guard let tab = tabs.current,
              let picker = tabs.accessories.first(where: { $0.accessory.placement == .popover })
            else { return }
            tabs.toggleAccessory(picker.id, on: tab.id)
          } label: {
            Image(systemName: "plus.rectangle.on.rectangle")
          }
          .accessibilityLabel("Shell")
          .help("Shell")
          .disabled(tabs.current == nil)
        #endif
        if let tab = tabs.current, tabs.wide {
          ForEach(toolbarAccessories) { plugin in
            accessoryButton(plugin, on: tab)
          }
        }
        if let workspace = extensionWorkspace {
          ForEach(workspace.commands) { command in
            Button(action: command.action) {
              Label(command.title, systemImage: command.symbol)
            }
            .buttonStyle(.iconOnly)
            .help(command.title)
          }
        }
        #if os(iOS)
          if tabs.wide {
            Button {
              _ = interaction.dispatch(.inspector, from: windowID)
            } label: {
              Label(tabs.title(for: .inspector), systemImage: "sidebar.right")
            }
            .buttonStyle(.iconOnly)
            .help(tabs.title(for: .inspector))
          }
        #endif
        if let id = tabs.selected, tabs.wide {
          Button {
            tabs.requestClose(id)
          } label: {
            Label("Close", systemImage: "xmark")
          }
          .buttonStyle(.iconOnly)
          .help("Close")
        }
      }
    }
    // The phone gives a plugin the screen, with one navigation bar and an
    // explicit Close action. The terminal's input is suspended underneath.
    .phonePluginCover(
      isPresented: Binding(
        get: { tabs.accessory != nil },
        set: { if !$0 { tabs.accessory = nil } }
      )
    ) {
      NavigationStack {
        Group {
          if let open = tabs.accessory, let tab = tabs.tabs.first(where: { $0.id == open.tab }) {
            if let attachment = tab.attachment(for: open.plugin) {
              tabs.placement(of: open.plugin) == .inspector
                ? attachment.inspector() : attachment.accessoryContent()
            } else {
              ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
        .navigationTitle(tabs.accessories.first(where: { $0.id == tabs.accessory?.plugin })?.title ?? "")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button {
              tabs.accessory = nil
            } label: {
              Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.iconOnly)
            .keyboardShortcut(.cancelAction)
          }
        }
        .modifier(PluginSheetPresentation(tabs: tabs, fromAccessory: true))
      }
    }
  }

  #if os(iOS)
    @ViewBuilder
    private var statusLamps: some View {
      ForEach(pluginStatusItems) { item in
        Button {
          openStatus(item)
        } label: {
          StatusRibbon(segments: item.segments)
            .frame(width: 44, height: Chrome.ribbonThickness)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .help(item.label)
      }
    }

    private func statusCover(_ panel: PhoneStatusPanel) -> some View {
      NavigationStack {
        panel.workspace.content()
          .navigationTitle(panel.workspace.title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button {
                closeStatus()
              } label: {
                Label("Close", systemImage: "xmark")
              }
              .buttonStyle(.iconOnly)
              .keyboardShortcut(.cancelAction)
              .accessibilityLabel("Close")
            }
          }
      }
    }

    @discardableResult
    private func openStatus(_ item: PluginStatusBarItem) -> Bool {
      guard let workspace = registry.plugins.first(where: { $0.metadata.id == item.id })?.statusBarWorkspace()
      else { return false }
      statusPanel?.workspace.close()
      statusPanel = PhoneStatusPanel(pluginID: item.id, workspace: workspace)
      return true
    }

    /// A tap names a plugin. Open its status page once that page exists;
    /// until then keep the id.
    private func openReturned(_ raw: String?) {
      if let raw, !raw.isEmpty { PluginOpen.pending = raw }
      guard let id = PluginOpen.pending,
        let item = pluginStatusItems.first(where: { $0.id == id }) else { return }
      if openStatus(item) { PluginOpen.pending = nil }
    }

    private func closeStatus() {
      statusPanel?.workspace.close()
      statusPanel = nil
    }
  #endif

  private func extensionContent(_ entry: WorkspaceEntry) -> some View {
    entry.workspace.content().id(entry.id)
      .terminalInputEnabled(terminalInputAllowed && tabs.selected == entry.id)
      .padding(Chrome.margin)
  }

  #if os(iOS)
    /// A phone's bar holds the commands and the shell picker, and no more:
    /// the rest of the buttons a wide screen shows went into the system's
    /// overflow, a second "more" beside this one. They are this menu's
    /// first section instead, under their names.
    @ViewBuilder
    private var foldedAccessories: some View {
      if let tab = tabs.current, !toolbarAccessories.isEmpty {
        Section {
          ForEach(toolbarAccessories) { plugin in
            Button {
              tabs.toggleAccessory(plugin.id, on: tab.id)
            } label: {
              Label(plugin.accessory.name.localizedCapitalized, systemImage: plugin.accessory.symbol)
            }
            .disabled(!tab.canOpen(plugin.id))
          }
        }
      }
    }

    /// The title switches terminals once there is one to switch to. With
    /// none open, a chevron would open a menu with nothing in it but New.
    private struct TerminalTitleMenu<Menu: View>: ViewModifier {
      let shown: Bool
      @ViewBuilder let menu: () -> Menu

      func body(content: Content) -> some View {
        if shown {
          content.toolbarTitleMenu { menu() }
        } else {
          content
        }
      }
    }

    /// The title's menu: every terminal open, by host, and a new one.
    @ViewBuilder
    private var terminalSwitcher: some View {
      ForEach(tabs.terminalChoices) { group in
        Section(group.title) {
          ForEach(group.choices) { choice in
            Button {
              tabs.select(choice.id)
            } label: {
              if choice.current {
                Label(choice.title, systemImage: "checkmark")
              } else {
                Text(choice.title)
              }
            }
          }
        }
      }
      Section {
        Button {
          _ = interaction.dispatch(.newTerminal, from: windowID)
        } label: {
          Label(tabs.title(for: .newTerminal), systemImage: "plus")
        }
      }
    }

  #endif

  /// On a phone the session picker opens from the shell button, so it is not
  /// also a button of its own. An inspector accessory stays where it is.
  private var toolbarAccessories: [PluginAccessory] {
    #if os(iOS)
      tabs.accessories.filter { $0.accessory.placement != .popover }
    #else
      tabs.accessories
    #endif
  }

  private func accessoryButton(_ plugin: PluginAccessory, on tab: SessionTab) -> some View {
    Button {
      tabs.toggleAccessory(plugin.id, on: tab.id)
    } label: {
      Label(plugin.accessory.name, systemImage: plugin.accessory.symbol)
    }
    .buttonStyle(.iconOnly)
    .help(plugin.accessory.name)
    .disabled(!tab.canOpen(plugin.id))
  }

  /// One terminal, filling the screen. Another one is a terminal to switch
  /// to, not a pane beside this one.
  private func phoneSession(_ tab: SessionTab) -> some View {
    Group {
      if let shown = tab.shown {
        shown.content()
      } else {
        SessionView(
          tab: tab, links: interaction.links(for: tab), menuItems: tabs.terminalMenu(for: tab.id), active: true, onFocus: {})
          .modifier(TerminalDrop(tab: tab) { interaction.drop($0, on: tab) })
      }
    }
    .id(tab.id)
    .terminalInputEnabled(terminalInputAllowed && tabs.selected == tab.id)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(tab.shown == nil ? 0 : Chrome.margin)
  }
}

extension RootView {
  /// Everything that belongs to the window rather than to either column.
  /// Split from the observers below: one chain is more than this compiler
  /// will type-check.
  @ViewBuilder
  fileprivate var windowChrome: some View {
    watchedWindow
    .onChange(of: route.requests) { _, _ in
      #if os(macOS)
        openSettings()
      #else
        showingSettings = true
      #endif
    }
    #if !os(macOS)
      .sheet(isPresented: $showingSettings) {
        NavigationStack(path: $route.phonePath) {
          AppSettings(registry: registry, known: tabs.known, store: store, secrets: secrets, connections: tabs, installedPlugins: installedPlugins)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingSettings = false }
              }
            }
        }
      }
      // Closed, it opens next time on its list, not the page left open.
      .onChange(of: showingSettings) { _, shown in if !shown { route.phonePath = [] } }
    #endif
    // Closing every session on the way out is not tidiness: each one holds a
    // socket and a task, and the far side is owed a disconnect rather than a
    // dropped connection. The notification is named differently on each
    // platform, and a phone can be killed without sending it at all — which
    // is why the sessions also close on `deinit`, not only here.
    .onReceive(NotificationCenter.default.publisher(for: terminationNotification)) { _ in
      tabs.shutdown()
    }
    .onAppear {
      registry.onDisable = { id in
        tabs.closePlugin(id)
        PluginLive.end(id)
      }
      // The startup role is the primary window's alone, not wherever the
      // effective host happens to be: library import questions and the
      // handoff listener belong to the one window that owns Settings.
      if isPrimaryWindow {
        store.handoff.start(store)
      }
    }
    .onChange(of: pluginStatusItems.map(\.id)) { _, ids in
      PluginLive.retain(Set(ids))
      #if os(iOS)
        openReturned(nil)
      #endif
    }
    #if os(iOS)
      .safeAreaInset(edge: .top, spacing: 0) {
        if !plugins.notes.isEmpty {
          PluginNoteStack(plugins: plugins, onOpen: PluginOpen.ask)
            .padding(.horizontal, UIStyle.Space.group)
            .padding(.bottom, UIStyle.Space.small)
        }
      }
    #else
      .overlay(alignment: .topTrailing) {
        PluginNoteStack(plugins: plugins, onOpen: PluginOpen.ask)
          .padding(UIStyle.Space.group)
      }
    #endif
    #if os(macOS)
      // A library import question is the primary window's, fixed — a
      // startup/Settings concern, not an ordinary workspace question, so
      // it is not routed through the effective host.
      .dialog(for: isPrimaryWindow ? store.pendingImport : nil) { offer in
        Dialog.confirm(
          offer.title, message: offer.message, detail: offer.diff, verb: "Import",
          cancel: { store.declineConfigurationImport() },
          perform: { store.acceptConfigurationImport() })
      }
    #endif
  }

  @ViewBuilder
  private var watchedWindow: some View {
    container
      .terminalInputEnabled(terminalInputAllowed)
      .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
      #if os(macOS)
        .background {
          WindowState(scheme: appearance == "system" ? nil : (appearance == "dark" ? .dark : .light)) { _ in }
            .allowsHitTesting(false)
        }
        .background {
          WorkspaceHostReporter(hostID: windowID, kind: .workspace, interaction: interaction)
            .allowsHitTesting(false)
        }
        .modifier(WorkspaceHostPresenters(
          tabs: tabs, interaction: interaction, hostID: windowID, store: store, registry: registry))
        .environment(\.isFrontWindow, presentsDialogs)
        .environment(\.surfaceDrivesSize, interaction.drivesSurface(windowID))
      #endif
      #if os(macOS)
        .background {
          WorkspaceKeyBindingMonitor(enabled: true, textEditingEnabled: true) {
            binding, repeated, editingText in
            handleWorkspaceShortcut(binding, repeated: repeated, editingText: editingText,
              interaction: interaction, hostID: windowID, registry: registry)
          }
          .allowsHitTesting(false)
        }
      #endif
      #if os(iOS)
        .overlay {
          PaletteOverlay(
            tabs: tabs, store: store,
            commands: interaction.commandItems(from: windowID),
            onPickHost: { interaction.open($0) })
        }
        .focusedSceneValue(\.workspaceShortcutsEnabled, shortcutsAllowed)
      #endif
      // On a Mac the accessory is a popover, so the window can present this.
      // A phone's accessory is a sheet, and a sheet's ancestor cannot present a
      // second one over it — so there it is presented from inside that sheet.
      .modifier(PluginSheetPresentation(tabs: tabs))
  }

  /// Which chords this window answers: the interaction decides, on
  /// the same list the quick panel reads.
  private var shortcutsAllowed: Bool {
    interaction.shortcutsAllowed(in: windowID)
  }

  /// ⌘1…⌘4 name the host they open. The binding table keeps "Host 1".
  private func hostLabel(_ action: WorkspaceAction) -> String? {
    guard let slot = action.hostSlot, store.listed.indices.contains(slot) else { return nil }
    return store.listed[slot].displayName
  }



}

#if os(macOS)
#endif

/// Something the window tells a person once, with nothing to decide.
struct WorkspaceNotice: Hashable {
  let id = UUID()
  let title: String
  let message: String
}

/// Where a tab plugin's sheet opens.
///
/// A modifier rather than a call site, because which view can present it
/// differs: a Mac's accessory is a popover and the window presents over it, a
/// phone's accessory is a sheet and only the sheet itself can.
private struct PluginSheetPresentation: ViewModifier {
  @Bindable var tabs: TabSet
  var fromAccessory = false

  func body(content: Content) -> some View {
    #if os(iOS)
      content.fullScreenCover(item: Binding(
        get: { fromAccessory || tabs.accessory == nil ? tabs.sheet : nil },
        set: { tabs.sheet = $0 }
      )) { sheet in
        sheet.view
      }
    #else
      content.sheet(item: $tabs.sheet) { sheet in
        sheet.view
      }
    #endif
  }
}

private extension View {
  @ViewBuilder
  func phonePluginCover<PluginContent: View>(
    isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> PluginContent
  ) -> some View {
    #if os(iOS)
      fullScreenCover(isPresented: isPresented, content: content)
    #else
      sheet(isPresented: isPresented, content: content)
    #endif
  }
}
