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

struct RootView: View {
  @Bindable var store: HostStore
  @Bindable var tabs: TabSet
  let registry: PluginRegistry
  let secrets: any SecretStore
  let plugins: PluginAPI
  @Binding var installedPlugins: InstalledPlugins?
  /// Where hosts are managed: Settings, opened at that page.
  @State private var route = SettingsRoute.shared
  /// Passwords to ask for before dialling, one at a time, in the order
  /// they were needed. A queue rather than a slot: two tabs can need one at
  /// once, and a question overwritten is a tab left waiting for nothing.
  @State private var connectRequests: [ConnectRequest] = []
  @State private var visibility: NavigationSplitViewVisibility = .all
  @State private var showingSettings = false
  /// A plugin's reconnect waiting on its own password question, by request.
  @State private var reconnectAnswers: [UUID: CheckedContinuation<String, Error>] = [:]
  /// Something that already went wrong, told once: a keychain that refused
  /// — silence would leave a person who ticked "remember" believing it was
  /// kept — or a host that cannot be connected to as configured.
  @State private var notice: WorkspaceNotice?
  @AppStorage("appearance") private var appearance = "system"
  #if os(macOS)
    @AppStorage(TetherUI.Palette.colorStyleKey) private var theme = TetherUI.Palette.defaultColorStyle
    @AppStorage(WorkspaceAppearance.opacityKey) private var backgroundOpacity = WorkspaceAppearance.defaultOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
  #endif
  @AppStorage(TabLayout.preferenceKey) private var tabLayout = TabLayout.default
  @Environment(\.openURL) private var openURL
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif
  #if os(macOS)
    /// On screen and key, as the window reports them; a scene would have said.
    @State private var windowShown = true
    @State private var windowKey = false
  #else
    @Environment(\.scenePhase) private var phase
  #endif
  #if os(iOS)
    /// Whether there is room for two columns. A phone in portrait is compact;
    /// an iPad, and a large phone turned sideways, are not.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Compact on a phone turned sideways, where every row counts.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The column a collapsed split view shows. Follows the selection, the
    /// way the stack it replaced pushed and popped with it.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    /// Whether the on-screen keyboard is up.
    @State private var keyboardShown = false
  #endif

  private var extensionWorkspace: (any PluginWorkspace)? {
    tabs.extensions.first { $0.id == tabs.selected }?.workspace
  }
  private var terminalInputAllowed: Bool {
    tabs.palette == nil && !tabs.hostPicker && tabs.accessory == nil
      && tabs.sheet == nil && tabs.pendingClose == nil && tabs.renaming == nil && tabs.renamingWorkspace == nil
      && connectRequests.isEmpty && !showingSettings
      && notice == nil
  }
  var body: some View {
    windowChrome
      .onAppear {
        tabs.onEmptied = { LastTabPreference.quitIfChosen() }
      }
  }

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
          if tabs.showsTabBar && tabLayout == .horizontal {
            WorkspaceTabBar(tabs: tabs, registry: registry, onClose: { id in
              if tabs.workspaces.contains(where: { $0.id == id }) { tabs.requestCloseWorkspace(id) }
              else { tabs.requestClose(id) }
            })
            // The split view's panes reach up under the titlebar; drawn
            // after the strip, they would take every click meant for a tab.
            .zIndex(1)
          } else {
            HStack(spacing: 0) {
              Color.clear.frame(width: Chrome.trafficLights)
              Color.clear.background { WindowDragArea() }
            }
            .frame(height: tabs.zen ? Chrome.titlebar : Chrome.tab)
            .background { WorkspaceMaterial() }
          }
          HSplitView {
            if tabs.showsTabBar && tabLayout == .vertical {
              WorkspaceTabBar(tabs: tabs, registry: registry, layout: .vertical, onClose: { id in
              if tabs.workspaces.contains(where: { $0.id == id }) { tabs.requestCloseWorkspace(id) }
              else { tabs.requestClose(id) }
            })
                .frame(minWidth: Chrome.tabSidebarMin, idealWidth: Chrome.tabSidebarIdeal,
                       maxWidth: Chrome.tabSidebarMax)
            }
            macCanvas
            // The inspector sits under the tab strip, not beside it in the
            // titlebar: its own header belongs to the column, in the same
            // row as the listing it controls (design 16-inspector).
            if showInspector {
              inspectorPane
                .scrollContentBackground(opacity < 1 ? .hidden : .automatic)
                .frame(minWidth: Chrome.inspectorMin, idealWidth: Chrome.inspectorIdeal, maxWidth: Chrome.inspectorMax)
                .frame(maxHeight: .infinity)
                .background { WorkspaceMaterial() }
            }
          }
          if !tabs.zen {
            HostStatusBar(
              tabs: tabs,
              store: store,
              pluginStatusItems: registry.plugins
                .filter { registry.isEnabled($0.metadata.id) }
                .compactMap(\.statusBarItem),
              statusBarLabel: { pluginID in
                registry.plugins.first { $0.metadata.id == pluginID }?.statusBarLabel()
              },
              statusBarSettings: { pluginID in
                registry.plugins.first { $0.metadata.id == pluginID }?.statusBarSettings()
              },
              makeStatusWorkspace: { pluginID in
                registry.plugins.first { $0.metadata.id == pluginID }?.statusBarWorkspace()
              })
          }
        }
        if tabs.hostPicker, !tabs.zen {
          Color.black.opacity(0.001)
            .ignoresSafeArea()
            .onTapGesture { tabs.hostPicker = false }
          HostPicker(tabs: tabs, store: store)
            .padding(.leading, UIStyle.panelRadius)
            .padding(.bottom, Chrome.status + UIStyle.Space.group)
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
    private var splitView: some View {
      NavigationSplitView(columnVisibility: columnVisibility, preferredCompactColumn: compactColumnChoice) {
        sidebar
      } detail: {
        phoneDetail
      }
      .navigationSplitViewStyle(.balanced)
      .onChange(of: tabs.selected, initial: true) { _, id in
        compactColumn = id == nil ? .sidebar : .detail
      }
      .onChange(of: [sizeClass, verticalSizeClass], initial: true) { _, _ in
        tabs.wide = sizeClass == .regular && verticalSizeClass == .regular
      }
      // There is no floating host picker here: the host list is the sidebar,
      // so asking for the picker — ⌘⇧H, or a new terminal with nowhere to
      // open it — shows that instead of an invisible panel holding the keys.
      .onChange(of: tabs.hostPicker) { _, asked in
        guard asked else { return }
        tabs.hostPicker = false
        if sizeClass == .compact { tabs.selected = nil } else { visibility = .all }
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
        keyboardShown = true
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
        keyboardShown = false
      }
    }

    /// Going back on a phone leaves the terminal running and no longer in
    /// front, as popping the stack did.
    private var compactColumnChoice: Binding<NavigationSplitViewColumn> {
      Binding(
        get: { compactColumn },
        set: { column in
          compactColumn = column
          if column == .sidebar, sizeClass == .compact { tabs.selected = nil }
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

  private var sidebar: some View {
    Sidebar(
      store: store,
      onOpen: { open($0) }, onEdit: { route.show(.edit($0.id)) }, onNew: { route.show(.newHost) },
      onSettings: { showingSettings = true }
    )
    .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
  }

  /// Opens a host, asking for a password only where one could be used.
  ///
  /// The question exists to collect a credential for a handshake. A shell on
  /// this machine has neither, so asking would be asking a person to
  /// dismiss a question about a stranger they are not talking to. A host
  /// that is already connected has spent that handshake; another terminal
  /// is another channel on the same lease. A host with an `IdentityFile`
  /// already has a credential — the key — and `ssh` would not ask for a
  /// password first either.
  private func open(_ host: Host, in workspaceID: UUID? = nil) {
    if host.isLocal {
      tabs.open(host, password: "", in: workspaceID)
      return
    }
    Task { await openRemote(host, in: workspaceID) }
  }

  private func splitTerminal(_ id: UUID, direction: SplitDirection) {
    guard let source = tabs.tabs.first(where: { $0.id == id }) else { return }
    if source.host.isLocal {
      tabs.splitTerminal(id, direction: direction)
      return
    }
    Task {
      do {
        let connection = try await source.connectionReady()
        guard tabs.tabs.contains(where: { $0.id == id }), tabs.currentHost?.id == source.host.id else { return }
        tabs.splitTerminal(id, direction: direction, on: connection)
      } catch {
        notice = WorkspaceNotice(title: "Could Not Split Terminal", message: error.localizedDescription)
      }
    }
  }

  private func openRemote(_ host: Host, in workspaceID: UUID? = nil) async {
    if let issue = host.connectionProblem {
      notice = WorkspaceNotice(title: "Could Not Connect", message: issue)
      return
    }
    do {
      if let connection = try await tabs.lease(for: host) {
        tabs.open(host, on: connection, in: workspaceID)
        return
      }
    } catch {
      // The in-flight handshake failed. Asking again is the remaining path.
    }
    switch await passwordSource(for: host) {
    case .none: tabs.open(host, password: "", in: workspaceID)
    case .saved(let password): tabs.open(host, password: password, in: workspaceID)
    case .ask: ask(ConnectRequest(host: host, workspaceID: workspaceID))
    }
  }

  private func restoreTab(_ id: UUID) {
    guard let record = tabs.restoration(for: id) else { return }
    let host = latest(record.host)
    if host.isLocal {
      finishRestore(record, tab: tabs.restore(id, host: host, password: ""))
      return
    }
    Task {
      if let issue = host.connectionProblem {
        tabs.cancelRestore(id)
        notice = WorkspaceNotice(title: "Could Not Connect", message: issue)
        return
      }
      if let connection = try? await tabs.lease(for: host) {
        finishRestore(record, tab: tabs.restore(id, host: host, on: connection))
        return
      }
      let source = await passwordSource(for: host)
      guard tabs.restoration(for: id) != nil else { return }
      switch source {
      case .none: finishRestore(record, tab: tabs.restore(id, host: host, password: ""))
      case .saved(let password): finishRestore(record, tab: tabs.restore(id, host: host, password: password))
      case .ask: ask(ConnectRequest(host: host, restoring: id))
      }
    }
  }

  private func finishRestore(_ record: ClosedTerminal, tab: SessionTab?) {
    guard let tab, let page = tabs.workspace(containing: tab.id) else { return }
    let members = record.members
    for (saved, terminalID) in zip(members, page.terminalIDs) {
      guard !saved.attachments.isEmpty, let terminal = tabs.tabs.first(where: { $0.id == terminalID }) else { continue }
      Task { [weak terminal] in
        guard let terminal else { return }
        guard (try? await terminal.connectionReady()) != nil,
          tabs.tabs.contains(where: { $0.id == terminal.id }) else { return }
        for attachment in saved.attachments {
          guard registry.isEnabled(attachment.pluginID) else { continue }
          prepareAttachment(attachment.pluginID, on: terminal)
          terminal.attachment(for: attachment.pluginID)?.restore(from: attachment.state)
        }
      }
    }
  }

  private func ask(_ request: ConnectRequest) {
    if let tab = request.retrying, connectRequests.contains(where: { $0.retrying == tab }) { return }
    connectRequests.append(request)
  }

  /// The host as it is now. A tab keeps the one it opened with; a password
  /// kept or a label edited since belongs to this one.
  private func latest(_ host: Host) -> Host {
    store.hosts.first { $0.id == host.id } ?? host
  }

  /// Where a handshake's password comes from: nowhere, because a key, a
  /// running master or this machine needs none; the keychain; or the person.
  private enum PasswordSource {
    case none
    case saved(String)
    case ask
  }

  /// A saved password comes first even for a host with a key: the key may
  /// be refused, or the server may ask for the password as well, and a
  /// password kept for that is one to use rather than to ask for again.
  private func passwordSource(for host: Host) async -> PasswordSource {
    if host.isLocal { return .none }
    if let password = remembered(for: host), !password.isEmpty { return .saved(password) }
    let master = host.allowsMasterReuse ? await TerminalSession.sshMasterIsRunning(host.sshTarget) : false
    if master || host.offersConfiguredKey { return .none }
    return .ask
  }

  /// Tries a tab again, in place, after the person asked to.
  ///
  /// After a refused login the person is asked, whatever is saved: sending
  /// the same refused password again is the loop this exists to break.
  private func retry(_ report: TabProblem) {
    guard let tab = tabs.tabs.first(where: { $0.id == report.tab }) else { return }
    tab.acknowledge()
    let host = latest(report.host)
    if report.problem.refusedLogin, !host.isLocal {
      ask(ConnectRequest(host: host, retrying: tab.id))
      return
    }
    Task {
      let source = await passwordSource(for: host)
      // Closed while the keychain was being read: nothing to try again.
      guard tabs.tabs.contains(where: { $0.id == tab.id }) else { return }
      switch source {
      case .none: tab.redial(host: host, password: "", typedNow: false)
      case .saved(let password): tab.redial(host: host, password: password, typedNow: false)
      case .ask: ask(ConnectRequest(host: host, retrying: tab.id))
      }
    }
  }

  /// The password question, answered.
  private func connect(_ request: ConnectRequest, password: String) {
    connectRequests.removeAll { $0.id == request.id }
    if let answer = reconnectAnswers.removeValue(forKey: request.id) {
      answer.resume(returning: password)
    } else if let id = request.restoring {
      guard let record = tabs.restoration(for: id) else { return }
      finishRestore(record, tab: tabs.restore(id, host: latest(request.host), password: password, typedNow: true))
    } else if let id = request.retrying {
      // A tab closed while its password was being asked for stays closed.
      tabs.tabs.first { $0.id == id }?.redial(host: latest(request.host), password: password, typedNow: true)
    } else {
      tabs.open(latest(request.host), password: password, typedNow: true, in: request.workspaceID)
    }
  }

  /// The password question, declined: nothing is dialled, and a failed tab
  /// that was waiting on it closes.
  private func cancelConnect(_ request: ConnectRequest) {
    connectRequests.removeAll { $0.id == request.id }
    reconnectAnswers.removeValue(forKey: request.id)?.resume(throwing: CancellationError())
    if let id = request.restoring { tabs.cancelRestore(id) }
    if let id = request.retrying { tabs.close(id) }
  }

  /// A password that worked, kept — or said why not.
  private func keep(_ offer: TabPasswordOffer) {
    keep(offer.offer.password, for: offer.host)
    tabs.answer(offer, kept: true)
  }

  #if os(macOS)
  #endif

  #if os(macOS)
  @ViewBuilder
  private var macCanvas: some View {
    if let layout = tabs.workspaceSplit {
      splitCanvas(layout)
    } else {
      canvas
    }
  }

  private func splitCanvas(_ layout: WorkspaceSplit) -> AnyView {
    switch layout {
    case .tab(let id):
      return AnyView(workspaceContent(id)
        .terminalInputEnabled(terminalInputAllowed && tabs.selected == id)
        .frame(minWidth: 120, maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { tabs.select(id) })
        .overlay(alignment: .top) {
          if tabs.selected == id {
            Rectangle().fill(Color.accentColor).frame(height: UIStyle.Mark.rule)
              .allowsHitTesting(false)
          }
        })
    case .split(.left, let first, let second), .split(.right, let first, let second):
      return AnyView(GeometryReader { geometry in
        HSplitView {
          splitCanvas(first).frame(idealWidth: geometry.size.width / 2)
          splitCanvas(second).frame(idealWidth: geometry.size.width / 2)
        }
      })
    case .split(.up, let first, let second), .split(.down, let first, let second):
      return AnyView(GeometryReader { geometry in
        VSplitView {
          splitCanvas(first).frame(idealHeight: geometry.size.height / 2)
          splitCanvas(second).frame(idealHeight: geometry.size.height / 2)
        }
      })
    }
  }
  #endif

  @ViewBuilder
  private func workspaceContent(_ id: UUID) -> some View {
    if let workspace = tabs.extensions.first(where: { $0.id == id })?.workspace {
      workspace.content().id(workspace.id).padding(Chrome.margin)
    } else if let tab = tabs.tabs.first(where: { $0.id == id }) {
      if let shown = tab.shown {
        shown.content().id(tab.id).padding(Chrome.margin)
      } else {
        SessionView(tab: tab, links: links(for: tab), menuItems: tabs.terminalMenu(for: tab.id), active: tabs.selected == id,
          onFocus: { tabs.select(id) }).id(tab.id)
          .modifier(TerminalDrop(tab: tab) { drop($0, on: tab) })
      }
    }
  }

  private var canvas: some View {
    Group {
      if let id = tabs.selected {
        workspaceContent(id)
      } else if tabs.currentHost != nil {
        EmptyWorkspace()
          .padding(Chrome.margin)
      } else {
        welcome
          .padding(Chrome.margin)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The window's second column, where there is a window to put one in:
  /// a Mac's, or an iPad's at full width.
  private var inspectorPane: some View {
    Group {
      if let workspace = extensionWorkspace {
        workspace.inspector()
      } else if let pluginID = tabs.inspectorPlugin,
        let attachment = tabs.current?.attachment(for: pluginID)
      {
        attachment.inspector()
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
        #if os(iOS)
          if tabs.wide, let layout = tabs.workspaceSplit, layout.ids.contains(tab.id) {
            touchSplitCanvas(layout)
          } else {
            phoneSession(tab)
          }
        #else
          phoneSession(tab)
        #endif
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
      ToolbarItemGroup(placement: .primaryAction) {
        #if os(iOS)
          Menu {
            if !tabs.wide { foldedAccessories }
            ForEach(Array(TouchCommands.sections(wide: tabs.wide).enumerated()), id: \.offset) { _, section in
              Section {
                ForEach(section, id: \.self) { action in
                  Button(tabs.title(for: action)) { tabs.perform(action) }
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
              tabs.perform(.inspector)
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
          tabs.perform(.newTerminal)
        } label: {
          Label(tabs.title(for: .newTerminal), systemImage: "plus")
        }
      }
    }

    /// Terminals side by side on an iPad, as the Mac splits them. Equal
    /// shares rather than dividers to drag: the layout is the same tree, and
    /// a pane is chosen by touching it.
    private func touchSplitCanvas(_ layout: WorkspaceSplit) -> AnyView {
      switch layout {
      case .tab(let id):
        return AnyView(touchPane(id))
      case .split(.left, let first, let second), .split(.right, let first, let second):
        return AnyView(HStack(spacing: 0) { touchSplitCanvas(first); Divider(); touchSplitCanvas(second) })
      case .split(.up, let first, let second), .split(.down, let first, let second):
        return AnyView(VStack(spacing: 0) { touchSplitCanvas(first); Divider(); touchSplitCanvas(second) })
      }
    }

    @ViewBuilder
    private func touchPane(_ id: UUID) -> some View {
      if let tab = tabs.tabs.first(where: { $0.id == id }) {
        phoneSession(tab, pane: true)
          .overlay(alignment: .top) {
            if tabs.selected == id {
              Rectangle().fill(Color.accentColor).frame(height: UIStyle.Mark.rule)
                .allowsHitTesting(false)
            }
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

  /// One terminal. In a split it is one `pane` of several, and only the
  /// selected one holds the keyboard; touching another selects it.
  private func phoneSession(_ tab: SessionTab, pane: Bool = false) -> some View {
    Group {
      if let shown = tab.shown {
        shown.content()
      } else {
        SessionView(tab: tab, links: links(for: tab), active: !pane || tabs.selected == tab.id,
          onFocus: { if pane { tabs.select(tab.id) } })
          .modifier(TerminalDrop(tab: tab) { drop($0, on: tab) })
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
    .onChange(of: tabs.intent) { _, intent in
      guard let intent else { return }
      tabs.intent = nil
      switch intent {
      case .splitTerminal(let id, let direction):
        splitTerminal(id, direction: direction)
      case .restoreTab(let id): restoreTab(id)
      case .addTerminal(let workspaceID):
        if let page = tabs.workspaces.first(where: { $0.id == workspaceID }) { open(page.host, in: workspaceID) }
      case .newTerminal:
        if let page = tabs.currentWorkspace { open(page.host, in: page.id) }
        else if TerminalSession.isLocalAvailable { open(.local) }
        else { tabs.hostPicker = true }
      case .newTab:
        if let host = tabs.currentHost {
          open(host)
        } else if TerminalSession.isLocalAvailable {
          open(.local)
        } else {
          tabs.hostPicker = true
        }
      case .connect(let host): open(host)
      case .reconnect(let id):
        if let report = tabs.reconnectReport(for: id) { retry(report) }
      case .edit(let host):
        tabs.hostPicker = false
        route.show(store.hosts.contains { $0.id == host.id } ? .edit(host.id) : .newHost)
      case .launchPlugin(let id):
        if let plugin = registry.plugins.first(where: { $0.metadata.id == id }),
          registry.isEnabled(id)
        {
          launch(plugin)
        }
      }
    }
    .onChange(of: route.requests) { _, _ in
      #if os(macOS)
        openSettings()
      #else
        showingSettings = true
      #endif
    }
    .dialog(for: tabs.pendingClose) { _ in
      Dialog.confirm(
        tabs.closeQuestion, message: tabs.closeNote, verb: tabs.pendingCloseVerb, role: .destructive,
        // Return is not a way to close a live shell; the same close chord
        // twice is (spec §6): ⌘W for a terminal, ⌥⌘W for a whole tab.
        shortcuts: [tabs.closingWorkspaceID == nil ? .command("w") : .commandOption("w")],
        cancel: { tabs.cancelClose() }, perform: { tabs.confirmClose() })
    }
    .dialog(for: tabs.renaming) { id in
      Dialog.input(
        "Rename", field: Dialog.Field("Name", initial: tabs.tabs.first { $0.id == id }?.name ?? ""),
        verb: "Save", cancel: { tabs.renaming = nil }, perform: { tabs.rename(id, to: $0) })
    }
    .dialog(for: tabs.renamingWorkspace) { id in
      Dialog.input(
        "Rename Tab", field: Dialog.Field("Name", initial: tabs.workspaces.first { $0.id == id }?.name ?? ""),
        verb: "Save", cancel: { tabs.renamingWorkspace = nil }, perform: { tabs.rename(id, to: $0) })
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
    .modifier(
      ConnectionDialogs(
        tabs: tabs, connecting: connectRequests.first, connect: connect, cancelConnect: cancelConnect,
        retry: retry, keep: keep, remembers: { latest($0).remembersPassword }))
    // Closing every session on the way out is not tidiness: each one holds a
    // socket and a task, and the far side is owed a disconnect rather than a
    // dropped connection. The notification is named differently on each
    // platform, and a phone can be killed without sending it at all — which
    // is why the sessions also close on `deinit`, not only here.
    .onReceive(NotificationCenter.default.publisher(for: terminationNotification)) { _ in
      tabs.shutdown()
    }
    .onAppear { registry.onDisable = { id in tabs.closePlugin(id) } }
    .dialog(for: notice) { shown in
      Dialog.notice(shown.title, message: shown.message) { notice = nil }
    }
    .overlay(alignment: .topTrailing) {
      PluginNoteStack(plugins: plugins)
        .padding(UIStyle.Space.group)
    }
    #if os(macOS)
      .dialog(for: store.pendingImport) { offer in
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
          WindowState(scheme: appearance == "system" ? nil : (appearance == "dark" ? .dark : .light)) {
            windowShown = $0.shown
            windowKey = $0.key
          }
          .allowsHitTesting(false)
        }
        .onChange(of: windowKey, initial: true) { _, _ in tabs.menuShortcuts = windowKey ? shortcutsAllowed : nil }
        .onChange(of: shortcutsAllowed) { _, _ in tabs.menuShortcuts = windowKey ? shortcutsAllowed : nil }
      #endif
      .overlay {
        PaletteOverlay(
          tabs: tabs, store: store, commands: commandItems, onPickHost: { open($0) })
      }
      #if os(macOS)
        .background {
          WorkspaceKeyBindingMonitor(enabled: shortcutsAllowed, textEditingEnabled: true) { binding, repeated, editingText in
            let definitions = KeyBindingCatalog.commands(registry: registry, tabs: tabs)
            guard let id = tabs.keyBindings.command(for: binding, in: definitions, offered: tabs.offeredCommandIDs),
              !editingText || WorkspaceAction.answersWhileEditingText(id)
            else { return false }
            if !repeated {
              if let action = WorkspaceAction(rawValue: id) { tabs.perform(action) }
              else if let item = commandItems.first(where: { $0.id == id && $0.enabled }) { item.run() }
            }
            return true
          }
          .allowsHitTesting(false)
        }
      #endif
      #if os(iOS)
        .focusedSceneValue(\.workspaceShortcutsEnabled, shortcutsAllowed)
      #endif
      .onChange(of: tabs.accessory) { _, open in
        guard let open, let tab = tabs.tabs.first(where: { $0.id == open.tab }) else { return }
        prepareAttachment(open.plugin, on: tab)
      }
      // The inspector follows the selected tab, so the tab now in front needs
      // its own attachment the first time it is shown there.
      .onChange(of: [tabs.inspectorPlugin, tabs.selected?.uuidString]) { _, _ in
        guard let pluginID = tabs.inspectorPlugin, let tab = tabs.current else { return }
        prepareAttachment(pluginID, on: tab)
      }
      .onChange(of: tabs.selected, initial: true) { _, _ in refreshFramePublishing() }
      .onChange(of: tabs.tabs.map(\.id), initial: true) { _, _ in refreshFramePublishing() }
      #if os(macOS)
        .onChange(of: windowShown) { _, _ in refreshFramePublishing() }
      #else
        .onChange(of: phase) { _, _ in refreshFramePublishing() }
      #endif
      .onChange(of: registry.disabled, initial: true) { _, _ in
        tabs.accessories = registry.plugins.compactMap { plugin in
          guard let plugin = plugin as? any TabPlugin, registry.isEnabled(plugin.metadata.id)
          else { return nil }
          return PluginAccessory(
            id: plugin.metadata.id, title: plugin.metadata.name, accessory: plugin.accessory)
        }
        attachLiveTabs()
      }
      // A wheel over the shell is offered to whatever is attached, which has
      // to exist before the accessory is opened: a full-screen program can
      // be keeping the history the wheel is asking for.
      .onChange(of: tabs.tabs.map(\.isLive), initial: true) { _, _ in attachLiveTabs() }
      // On a Mac the accessory is a popover, so the window can present this.
      // A phone's accessory is a sheet, and a sheet's ancestor cannot present a
      // second one over it — so there it is presented from inside that sheet.
      .modifier(PluginSheetPresentation(tabs: tabs))
  }

  /// Sheets and authentication questions own their keyboard while presented.
  private var shortcutsAllowed: Bool {
    #if os(iOS)
      if tabs.accessory != nil || tabs.palette != nil || tabs.hostPicker { return false }
    #endif
    return tabs.sheet == nil && tabs.pendingClose == nil && tabs.renaming == nil && tabs.renamingWorkspace == nil
      && connectRequests.isEmpty
      && !showingSettings && notice == nil
      && tabs.problem == nil && tabs.passwordOffer == nil
  }

  private var commandItems: [CommandItem] {
    let definitions = KeyBindingCatalog.commands(registry: registry, tabs: tabs)
    func detail(_ command: KeyBindingCommand) -> String {
      let shortcut = tabs.keyBindings.summary(for: command)
      return shortcut.isEmpty ? command.group : "\(command.group) · \(shortcut)"
    }
    var items = WorkspaceAction.available.filter { tabs.wide || !$0.needsWidth }.map { action in
      let command = action.command
      return CommandItem(
        id: command.id,
        // Keep the searchable toggle name consistent with Key Bindings.
        // Native menus and the titlebar button still say Show/Hide Tab Bar.
        title: action == .toggleTabBar ? command.title : tabs.title(for: action),
        // From the palette these close what is behind it, never the window.
        detail: detail(command),
        enabled: [.closeTerminal, .closeTab].contains(action) ? tabs.selected != nil : tabs.canPerform(action)
      ) {
        tabs.palette = nil
        tabs.perform(action)
      }
    }
    for plugin in registry.plugins where registry.isEnabled(plugin.metadata.id) {
      let id = plugin.metadata.id
      if !plugin.isStatusBarOnly, let definition = definitions.first(where: { $0.id == KeyBindingCatalog.launchID(id) }) {
        let blocked = plugin is any TabPlugin
          ? tabs.current?.canOpen(id) != true
          : plugin.needsRemoteConnection && tabs.current?.connection == nil
        items.append(CommandItem(id: definition.id, title: definition.title,
                                 detail: detail(definition), enabled: !blocked) {
          tabs.palette = nil
          launch(plugin)
        })
      }
      let commands: [PluginCommand]
      if let entry = tabs.extensions.first(where: { $0.id == tabs.selected && $0.pluginID == id }) {
        commands = entry.workspace.commands
      } else {
        commands = tabs.current?.attachment(for: id)?.commands ?? []
      }
      for command in commands {
        let commandID = KeyBindingCatalog.commandID(command.id, plugin: id)
        guard let definition = definitions.first(where: { $0.id == commandID }) else { continue }
        items.append(CommandItem(id: commandID, title: command.title,
                                 detail: detail(definition), enabled: true) {
          tabs.palette = nil
          command.action()
        })
      }
    }
    return items
  }


  /// What the keychain already has for this host, if the person asked for it
  /// to be kept. Read at the moment of connecting, not held in memory: a
  /// password sitting in a view model is a password in a crash report.
  ///
  /// A keychain that refuses is said so, before the person is asked to type
  /// what it would not give: otherwise the question looks like a password
  /// that was forgotten.
  private func remembered(for host: Host) -> String? {
    guard host.remembersPassword else { return nil }
    do {
      return try secrets.password(for: host.passwordID)
    } catch {
      notice = WorkspaceNotice(title: "Could Not Read Password for \(host.displayName)", message: message(for: error))
      return nil
    }
  }

  /// Records or clears what a person asked to be remembered.
  ///
  /// The flag on the host and the item in the keychain are two facts that
  /// must agree: a host marked as remembering with nothing stored prefills
  /// an empty field for ever, so a keychain that refuses leaves the flag off.
  /// Keeps a password that has just worked. Only for a host that is still
  /// in the list: a login can outlive the host it was for, and a deleted
  /// host must not come back through its keychain item.
  ///
  /// Kept through the host's record, like everything else about it.
  private func keep(_ password: String, for host: Host) {
    guard let host = store.hosts.first(where: { $0.id == host.id }) else {
      notSaved(host, "This host is no longer in the list.")
      return
    }
    if !store.save(host, password: password) { notSaved(host, store.problem) }
  }

  private func notSaved(_ host: Host, _ problem: String?) {
    notice = WorkspaceNotice(title: "Could Not Save Password for \(host.displayName)", message: problem ?? "")
  }

  private func shellLabel(for tab: SessionTab?) -> String {
    if tab?.host.isLocal == true, let path = ProcessInfo.processInfo.environment["SHELL"], !path.isEmpty {
      return URL(fileURLWithPath: path).lastPathComponent
    }
    return "Shell"
  }

  private func pluginContext(for tab: SessionTab, pluginID: String = "", pluginName: String = "") -> PluginContext {
    return PluginContext(
      connection: tab.connection,
      hostLabel: tab.host.label.isEmpty ? tab.host.hostname : tab.host.label,
      hostID: tab.host.id,
      shellLabel: shellLabel(for: tab),
      pluginID: pluginID,
      pluginName: pluginName,
      openWorkspace: { _ in },
      reconnect: { [weak tab] in
        guard let tab else { throw CancellationError() }
        return try await reconnect(host: tab.host)
      }
    )
  }

  /// Only the tab in front copies a frame, and only while the app is in
  /// front. The others stay subscribed, so the next time they are shown
  /// the screen they copy is the current one. Every tab keeps reading:
  /// a session left unread backs up to its far side, and a server drops
  /// a client that has stopped answering (`TerminalSession.pause`).
  private func refreshFramePublishing() {
    #if os(macOS)
      let foreground = windowShown
    #else
      let foreground = phase != .background
    #endif
    for tab in tabs.tabs {
      tab.setPublishesFrames(foreground && (tab.id == tabs.selected || tabs.workspaceSplit?.ids.contains(tab.id) == true))
    }
  }

  /// Attaches every tab plugin on a live tab, once. The accessory used to
  /// be the first time; a wheel can need the attachment before that opens.
  private func attachLiveTabs() {
    for tab in tabs.tabs where tab.isLive {
      for plugin in tabs.accessories {
        prepareAttachment(plugin.id, on: tab)
      }
    }
  }

  /// Makes the tab's attachment for this plugin the first time its
  /// accessory opens there, and hands an existing one the tab's current
  /// lease — which a reconnect may have replaced since.
  private func prepareAttachment(_ pluginID: String, on tab: SessionTab) {
    if let attachment = tab.attachment(for: pluginID) {
      if let connection = tab.connection { attachment.connectionChanged(connection) }
      return
    }
    guard let plugin = registry.plugins.first(where: { $0.metadata.id == pluginID }) as? any TabPlugin,
      registry.isEnabled(pluginID)
    else { return }
    tab.attach(plugin.attach(to: tabContext(for: tab, plugin: plugin)), for: pluginID)
  }

  private func tabContext(for tab: SessionTab, plugin: any TetherPlugin) -> TabContext {
    let id = tab.id
    let pluginID = plugin.metadata.id
    return TabContext(
      id: id,
      plugin: pluginContext(for: tab, pluginID: pluginID, pluginName: plugin.metadata.name),
      terminalName: { [weak tab] in tab?.terminalName },
      focus: { tabs.select(id) },
      dismissAccessory: { tabs.dismissAccessory(pluginID, on: id) },
      present: { view in tabs.sheet = PluginSheet(tab: id, plugin: pluginID, view: view) },
      dismissSheet: { if tabs.sheet?.tab == id { tabs.sheet = nil } },
      insertText: { [weak tab] text in tab?.send(.paste(text)) },
      runInTerminal: { [weak tab] line in
        tab?.send(.paste(line))
        tab?.send(.key(.enter))
      },
      workingDirectory: { [weak tab] in tab?.workingDirectory },
      resolveWorkingDirectory: { [weak tab] link in
        guard let tab else { return nil }
        return await workingDirectory(for: link, on: tab)
      },
      showAccessory: { tabs.showAccessory(pluginID, on: id) },
      linkActions: { [weak tab] pointed in tab.flatMap { linkActions(for: pointed, on: $0) } },
      shells: {
        let members = tabs.workspace(containing: id)?.terminalIDs ?? []
        return members.compactMap { terminalID in
          tabs.tabs.first { $0.id == terminalID }.map { ShellChoice(id: $0.id, title: $0.title, current: $0.id == tabs.selected) }
        }
      },
      openShell: { tabs.select($0) },
      newShell: {
        if let page = tabs.workspace(containing: id) { tabs.intent = .addTerminal(page.id) }
      },
      scrollBy: { [weak tab] lines in tab?.scrollOwnHistory(by: lines) },
      reportWheel: { [weak tab] lines, column, row in
        guard let tab, lines != 0 else { return }
        let button: PointerButton = lines > 0 ? .wheelUp : .wheelDown
        for _ in 0..<WheelReports.count(lines) {
          tab.send(.pointer(button: button, phase: .press, column: column, row: row))
        }
      },
      mouseTracking: { [weak tab] in tab?.frame?.mouse ?? .off })
  }

  /// What pointing at the terminal does on this tab: whatever its plugins
  /// offer, read relative to where the tab's shell said it was.
  private func links(for tab: SessionTab) -> TerminalLinks {
    TerminalLinks(
      find: { [weak tab] row, column in tab?.link(atRow: row, column: column) },
      actions: { [weak tab] link in
        guard let tab else { return nil }
        return linkActions(
          for: PointedLink(link: link, directory: { [weak tab] in
            guard let tab else { return nil }
            return await workingDirectory(for: link, on: tab)
          }),
          on: tab)
      })
  }

  private func workingDirectory(for link: TerminalLink?, on tab: SessionTab) async -> String? {
    for plugin in tabs.accessories { prepareAttachment(plugin.id, on: tab) }
    for item in tab.attachments {
      if let directory = await item.attachment.workingDirectory(for: link) { return directory }
    }
    return tab.workingDirectory
  }

  /// Everything offered for a link on a tab, as one.
  ///
  /// A web address opens in the browser, which needs nobody's help. Anything
  /// else is offered to the tab's plugins — attaching them first, since
  /// pointing at a path is as much a reason to need one as opening its
  /// accessory — and the menu always has the text itself to copy.
  private func linkActions(for pointed: PointedLink, on tab: SessionTab) -> LinkActions? {
    let copy = PluginCommand(id: "copy", title: "Copy", symbol: "doc.on.doc") {
      copyToPasteboard(pointed.link.text)
    }
    if let url = webAddress(pointed.link) {
      let open = PluginCommand(id: "openLink", title: "Open Link", symbol: "safari") {
        openURL(url)
      }
      return LinkActions(open: { openURL(url) }, commands: [open, copy], exists: { true })
    }
    for plugin in tabs.accessories { prepareAttachment(plugin.id, on: tab) }
    let offers = tab.attachments.compactMap { $0.attachment.actions(for: pointed) }
    guard let combined = LinkActions.combining(offers) else {
      // Nothing can look for it: copyable, but not underlined as a promise.
      return LinkActions(commands: [copy], exists: { false })
    }
    return LinkActions(
      open: combined.open, preview: combined.preview, commands: combined.commands + [copy],
      exists: combined.exists)
  }

  /// A link that is a web page, whether printed or attached with `OSC 8`.
  private func webAddress(_ link: TerminalLink) -> URL? {
    let text: String
    switch link.kind {
    case .url(let url): text = url
    case .hyperlink(let uri): text = uri
    case .path: return nil
    }
    guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased())
    else { return nil }
    return url
  }

  /// A path dragged from the files list is pasted as that absolute path.
  /// Anything else that is a file is handed to `receiveFiles`.
  private struct TerminalDrop: ViewModifier {
    let tab: SessionTab
    let receiveFiles: ([URL]) -> Void

    func body(content: Content) -> some View {
      content.onDrop(of: [DroppedPath.contentType, .fileURL], isTargeted: nil) { providers in
        let carried = providers.filter {
          $0.hasItemConformingToTypeIdentifier(DroppedPath.contentType.identifier)
        }
        if !carried.isEmpty {
          Task { @MainActor in
            var texts: [String] = []
            for provider in carried {
              if let item = await Self.load(DroppedPath.self, from: provider) {
                texts.append(item.text)
              }
            }
            let text = texts.joined(separator: "\n")
            guard !text.isEmpty else { return }
            tab.send(.paste(text))
          }
          return true
        }
        Task { @MainActor in
          var urls: [URL] = []
          for provider in providers {
            if let url = await Self.load(URL.self, from: provider), url.isFileURL {
              urls.append(url)
            }
          }
          receiveFiles(urls)
        }
        return !providers.isEmpty
      }
    }

    private static func load<T: Transferable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
      await withCheckedContinuation { continuation in
        _ = provider.loadTransferable(type: type) { result in
          continuation.resume(returning: try? result.get())
        }
      }
    }
  }

  /// Files dropped on a terminal from outside the files list.
  ///
  /// On this machine a terminal types their paths, which is what every
  /// terminal does and all a local shell needs. Anywhere else a local path
  /// means nothing, so the tab's plugins are offered them — the first to
  /// take them decides what a drop means there. A path dragged out of the
  /// files list is not one of these: that drop is the absolute path itself.
  private func drop(_ urls: [URL], on tab: SessionTab) {
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else { return }
    if tab.host.isLocal {
      tab.send(.paste(files.map { shellQuoted($0.path) }.joined(separator: " ") + " "))
      return
    }
    for plugin in tabs.accessories { prepareAttachment(plugin.id, on: tab) }
    // First taker wins, which is what `contains` short-circuited on — spelled
    // as a loop because no caller consumes whether anyone took them.
    for attachment in tab.attachments {
      if attachment.attachment.receive(files: files) { break }
    }
  }

  private func reconnect(host: Host) async throws -> RemoteConnection {
    let host = latest(host)
    if let connection = try? await tabs.lease(for: host) {
      return connection
    }
    let password: String
    let typedNow: Bool
    switch await passwordSource(for: host) {
    case .none:
      (password, typedNow) = ("", false)
    case .saved(let saved):
      (password, typedNow) = (saved, false)
    case .ask:
      typedNow = true
      let request = ConnectRequest(host: host)
      password = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          reconnectAnswers[request.id] = continuation
          ask(request)
        }
      } onCancel: {
        Task { @MainActor in
          connectRequests.removeAll { $0.id == request.id }
          reconnectAnswers.removeValue(forKey: request.id)?.resume(throwing: CancellationError())
        }
      }
    }
    let selected = tabs.selected
    tabs.open(host, password: password, typedNow: typedNow)
    guard let tab = tabs.current else { throw CancellationError() }
    let connection = try await withTaskCancellationHandler {
      try await tab.connectionReady()
    } onCancel: {
      Task { @MainActor in tabs.close(tab.id) }
    }
    tabs.selected = selected
    return connection
  }

  private func launch(_ plugin: any TetherPlugin) {
    let tab = tabs.current
    // A tab plugin has nothing to open but its accessory, on this tab.
    if plugin is any TabPlugin {
      guard let tab, tab.canOpen(plugin.metadata.id) else { return }
      tabs.toggleAccessory(plugin.metadata.id, on: tab.id)
      return
    }
    if plugin.needsRemoteConnection {
      guard tab?.connection != nil else { return }
    }
    let host = tab?.host
    plugin.launch(
      in: PluginContext(
        connection: tab?.connection,
        hostLabel: host.map { $0.label.isEmpty ? $0.hostname : $0.label } ?? "",
        hostID: host?.id ?? UUID(),
        shellLabel: shellLabel(for: tab),
        pluginID: plugin.metadata.id,
        pluginName: plugin.metadata.name,
        openWorkspace: { workspace in
          tabs.openExtension(
            workspace,
            pluginID: plugin.metadata.id,
            hostID: plugin.needsRemoteConnection ? host?.id : nil)
        },
        reconnect: {
          guard let host else { throw CancellationError() }
          return try await reconnect(host: host)
        }))
  }
  private var welcome: some View {
    EmptyWorkspace()
  }
}

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
