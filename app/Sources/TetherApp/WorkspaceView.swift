import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif
import Tether
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
  @State private var editing: Host?
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
  @AppStorage(TabLayout.preferenceKey) private var tabLayout = TabLayout.default
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var phase
  #if !os(macOS)
    /// Whether there is room for two columns. A phone in portrait is compact;
    /// an iPad, and a phone turned sideways, are not.
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  private var extensionWorkspace: (any PluginWorkspace)? {
    tabs.extensions.first { $0.id == tabs.selected }?.workspace
  }
  private var terminalInputAllowed: Bool {
    tabs.palette == nil && !tabs.hostPicker && tabs.accessory == nil
      && tabs.sheet == nil && tabs.pendingClose == nil && tabs.renaming == nil
      && !tabs.manageHosts && editing == nil && connectRequests.isEmpty && !showingSettings
      && notice == nil
  }
  var body: some View {
    windowChrome
      .onAppear {
        tabs.onEmptied = { LastTabPreference.quitIfChosen() }
      }
  }

  /// Two columns where there is room for two, a stack where there is not.
  ///
  /// A collapsed `NavigationSplitView` shows its sidebar and pushes the
  /// detail only when a `NavigationLink` is followed. Nothing here is a link —
  /// opening a host goes through a sheet first — so on a phone a session
  /// opened behind the list and stayed there: connected, drawing, invisible.
  /// The stack is driven by the same selection the split view uses, so both
  /// shapes agree about what is open.
  @ViewBuilder
  private var container: some View {
    #if os(macOS)
      macWorkspace
    #else
      if sizeClass == .compact {
        NavigationStack {
          sidebar
            .navigationDestination(item: $tabs.selected) { _ in
              phoneDetail.navigationBarTitleDisplayMode(.inline)
            }
        }
      } else {
        splitView
      }
    #endif
  }

  #if os(macOS)
    private var macWorkspace: some View {
      ZStack(alignment: .bottomLeading) {
        VStack(spacing: 0) {
          if tabs.showsTabBar && tabLayout == .horizontal {
            WorkspaceTabBar(tabs: tabs, onClose: { tabs.requestClose($0) })
          } else {
            HStack(spacing: 0) {
              Color.clear.frame(width: Chrome.trafficLights)
              if !tabs.zen { TabBarToggle(tabs: tabs) }
              Color.clear.background { WindowDragArea() }
            }
            .frame(height: tabs.zen ? Chrome.titlebar : Chrome.tab)
            .background(tabs.zen ? Theme.window : Theme.sidebar)
          }
          HSplitView {
            if tabs.showsTabBar && tabLayout == .vertical {
              WorkspaceTabBar(tabs: tabs, layout: .vertical, onClose: { tabs.requestClose($0) })
                .frame(minWidth: Chrome.tabSidebarMin, idealWidth: Chrome.tabSidebarIdeal,
                       maxWidth: Chrome.tabSidebarMax)
            }
            canvas
            // The inspector sits under the tab strip, not beside it in the
            // titlebar: its own header belongs to the column, in the same
            // row as the listing it controls (design 16-inspector).
            if showInspector {
              inspectorPane
                .frame(minWidth: Chrome.inspectorMin, idealWidth: Chrome.inspectorIdeal, maxWidth: Chrome.inspectorMax)
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar)
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
      .background(Theme.window)
      .background { CompactTitlebar() }
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

  private var splitView: some View {
    NavigationSplitView(columnVisibility: $visibility) {
      sidebar
    } detail: {
      phoneDetail
    }
    .navigationSplitViewStyle(.balanced)
  }

  private var sidebar: some View {
    Sidebar(
      store: store,
      onOpen: open, onEdit: { editing = $0 }, onNew: { editing = .blank() },
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
  private func open(_ host: Host) {
    if host.isLocal {
      tabs.open(host, password: "")
      return
    }
    Task { await openRemote(host) }
  }

  private func openRemote(_ host: Host) async {
    if let issue = host.connectionProblem {
      notice = WorkspaceNotice(title: "Could Not Connect", message: issue)
      return
    }
    do {
      if let connection = try await tabs.lease(for: host) {
        tabs.open(host, on: connection)
        return
      }
    } catch {
      // The in-flight handshake failed. Asking again is the remaining path.
    }
    switch await passwordSource(for: host) {
    case .none: tabs.open(host, password: "")
    case .saved(let password): tabs.open(host, password: password)
    case .ask: ask(ConnectRequest(host: host))
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
    guard let tab, !record.attachments.isEmpty else { return }
    Task { [weak tab] in
      guard let tab, (try? await tab.connectionReady()) != nil,
        tabs.tabs.contains(where: { $0.id == tab.id }) else { return }
      for saved in record.attachments {
        guard registry.isEnabled(saved.pluginID) else { continue }
        prepareAttachment(saved.pluginID, on: tab)
        tab.attachment(for: saved.pluginID)?.restore(from: saved.state)
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
      tabs.open(latest(request.host), password: password, typedNow: true)
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

  private var canvas: some View {
    Group {
      if let workspace = extensionWorkspace {
        workspace.content().id(workspace.id)
          .padding(Chrome.margin)
      } else if let tab = tabs.current {
        if let shown = tab.shown {
          shown.content().id(tab.id)
            .padding(Chrome.margin)
        } else {
          // The grid is the column. A window-colored gutter around it read
          // as a second frame; the glyph margin lives inside the surface.
          SessionView(tab: tab, links: links(for: tab)).id(tab.id)
            .modifier(TerminalDrop(tab: tab) { drop($0, on: tab) })
        }
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

  /// The window's second column, where there is a window to put one in.
  #if os(macOS)
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
              LabeledContent("Status", value: tab.isLive ? "Connected" : "Not connected")
            }
          }.formStyle(.grouped)
        } else {
          QuietMark("No workspace selected", systemImage: "sidebar.right")
        }
      }
    }
  #endif

  private var phoneDetail: some View {
    Group {
      if tabs.tabs.isEmpty && tabs.extensions.isEmpty {
        EmptyWorkspace()
      } else if tabs.extensions.isEmpty,
        let tab = tabs.tabs.first(where: { $0.id == tabs.selected }) ?? tabs.visibleTabs.first
      {
        // Several terminals share the session menu. A tab bar under the keys
        // was a second list of the same sessions.
        phoneSession(tab)
      } else if tabs.tabs.isEmpty, let entry = tabs.extensions.first {
        entry.workspace.content().id(entry.id)
          .terminalInputEnabled(terminalInputAllowed && tabs.selected == entry.id)
          .padding(Chrome.margin)
      } else {
        TabView(selection: phoneTabSelection) {
          ForEach(tabs.tabs) { tab in
            phoneSession(tab)
              .tabItem {
                Image(systemName: "terminal").accessibilityLabel(tab.title)
              }
              .tag(Optional(tab.id))
          }
          ForEach(tabs.extensions) { entry in
            entry.workspace.content().id(entry.id)
              .terminalInputEnabled(terminalInputAllowed && tabs.selected == entry.id)
              .padding(Chrome.margin)
              .tabItem {
                Image(systemName: entry.workspace.symbol).accessibilityLabel(entry.workspace.title)
              }
              .tag(Optional(entry.id))
          }
        }
        #if os(iOS)
          .toolbar(
            tabs.tabs.count + tabs.extensions.count > 1 ? .visible : .hidden, for: .tabBar)
        #endif
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(extensionWorkspace?.title ?? tabs.current?.title ?? "Tether")
    // Two buttons: where this terminal is, and closing it. The connection's
    // host, user and port were a third — a pane of four facts the host row
    // in the sidebar already carries, on a screen with room for neither.
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        #if os(iOS)
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
        if let tab = tabs.current {
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
        if let id = tabs.selected {
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
    // A sheet on the view rather than a popover on the button: a phone
    // adapts a popover into a sheet anyway, and one anchored inside a
    // toolbar group has no anchor of its own to adapt from.
    .sheet(
      isPresented: Binding(
        get: { tabs.accessory != nil },
        set: { if !$0 { tabs.accessory = nil } }
      )
    ) {
      Group {
        if let open = tabs.accessory, let tab = tabs.tabs.first(where: { $0.id == open.tab }) {
          if let attachment = tab.attachment(for: open.plugin) {
            // No inspector here: what a Mac keeps beside the terminal is
            // what this sheet shows.
            tabs.placement(of: open.plugin) == .inspector
              ? attachment.inspector() : attachment.accessoryContent()
          } else {
            // The attachment is made as the sheet opens; an empty sheet
            // would read as "nothing there" rather than as "not asked yet".
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      .modifier(PluginSheetPresentation(tabs: tabs))
    }
  }

  private var phoneTabSelection: Binding<UUID?> {
    Binding(
      get: { tabs.selected },
      set: { if let id = $0 { tabs.select(id) } })
  }

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

  private func phoneSession(_ tab: SessionTab) -> some View {
    Group {
      if let shown = tab.shown {
        shown.content()
      } else {
        SessionView(tab: tab)
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
      case .restoreTab(let id): restoreTab(id)
      case .newTerminal:
        if let host = tabs.currentHost {
          open(host)
        } else if TerminalSession.isLocalAvailable {
          open(.local)
        } else {
          tabs.hostPicker = true
        }
      case .connect(let host): open(host)
      case .edit(let host):
        tabs.hostPicker = false
        editing = host
      case .launchPlugin(let id):
        if let plugin = registry.plugins.first(where: { $0.metadata.id == id }),
          registry.isEnabled(id)
        {
          launch(plugin)
        }
      }
    }
    .sheet(item: $editing) { host in
      HostEditor(host: host, password: (try? secrets.password(for: host.passwordID)) ?? "") {
        store.save($0, password: $1)
      }
    }
    .sheet(isPresented: $tabs.manageHosts) {
      Group {
        Sidebar(
          store: store,
          onOpen: { host in
            tabs.manageHosts = false
            open(host)
          },
          onEdit: { host in
            tabs.manageHosts = false
            editing = host
          },
          onNew: { editing = .blank() },
          onSettings: { showingSettings = true },
          onDone: { tabs.manageHosts = false }
        )
      }
      #if os(macOS)
        .frame(minWidth: UIStyle.panelWidth, minHeight: Chrome.editorHeight)
      #else
        .modifier(HostManagementNavigation())
      #endif
    }
    .dialog(for: tabs.pendingClose) { _ in
      Dialog.confirm(
        tabs.closeQuestion, message: tabs.closeNote, verb: "Close Tab", role: .destructive,
        shortcuts: [.enter, .command("w")],
        cancel: { tabs.pendingClose = nil }, perform: { tabs.confirmClose() })
    }
    .dialog(for: tabs.renaming) { id in
      Dialog.input(
        "Rename", field: Dialog.Field("Name", initial: tabs.tabs.first { $0.id == id }?.name ?? ""),
        verb: "Save", cancel: { tabs.renaming = nil }, perform: { tabs.rename(id, to: $0) })
    }
    #if !os(macOS)
      .sheet(isPresented: $showingSettings) {
        NavigationStack {
          AppSettings(registry: registry, known: tabs.known, store: store, secrets: secrets, connections: tabs)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingSettings = false }
              }
            }
        }
      }
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
      .overlay {
        PaletteOverlay(
          tabs: tabs, store: store, commands: commandItems, onPickHost: open)
      }
      #if os(macOS)
        .background {
          WorkspaceKeyBindingMonitor(enabled: shortcutsAllowed, textEditingEnabled: true) { binding, repeated in
            let definitions = KeyBindingCatalog.commands(registry: registry, tabs: tabs)
            guard let id = tabs.keyBindings.command(for: binding, in: definitions) else { return false }
            if !repeated {
              if let action = WorkspaceAction(rawValue: id) { tabs.perform(action) }
              else if let item = commandItems.first(where: { $0.id == id && $0.enabled }) { item.run() }
            }
            return true
          }
          .allowsHitTesting(false)
        }
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
      .onChange(of: phase) { _, _ in refreshFramePublishing() }
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
      #if os(macOS)
        .modifier(PluginSheetPresentation(tabs: tabs))
      #endif
  }

  /// Sheets and authentication questions own their keyboard while presented.
  private var shortcutsAllowed: Bool {
    tabs.sheet == nil && tabs.pendingClose == nil && tabs.renaming == nil
      && !tabs.manageHosts && editing == nil && connectRequests.isEmpty
      && !showingSettings && notice == nil
      && tabs.problem == nil && tabs.passwordOffer == nil
  }

  private var commandItems: [CommandItem] {
    let definitions = KeyBindingCatalog.commands(registry: registry, tabs: tabs)
    func detail(_ command: KeyBindingCommand) -> String {
      let shortcut = tabs.keyBindings.summary(for: command)
      return shortcut.isEmpty ? command.group : "\(command.group) · \(shortcut)"
    }
    var items = WorkspaceAction.available.map { action in
      let command = action.command
      return CommandItem(
        id: command.id,
        // Keep the searchable toggle name consistent with Key Bindings.
        // Native menus and the titlebar button still say Show/Hide Tab Bar.
        title: action == .toggleTabBar ? command.title : tabs.title(for: action),
        detail: detail(command), enabled: action == .closeTab ? tabs.selected != nil : tabs.canPerform(action)
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
      notice = WorkspaceNotice(title: "The Saved Password Could Not Be Read", message: message(for: error))
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
      notSaved("This host is no longer in the list.")
      return
    }
    if !store.save(host, password: password) { notSaved(store.problem) }
  }

  private func notSaved(_ problem: String?) {
    notice = WorkspaceNotice(title: "The Password Was Not Saved", message: problem ?? "")
  }

  private func pluginContext(for tab: SessionTab) -> PluginContext {
    let shellLabel: String
    if tab.host.isLocal, let path = ProcessInfo.processInfo.environment["SHELL"], !path.isEmpty {
      shellLabel = URL(fileURLWithPath: path).lastPathComponent
    } else {
      shellLabel = "Shell"
    }
    return PluginContext(
      connection: tab.connection,
      hostLabel: tab.host.label.isEmpty ? tab.host.hostname : tab.host.label,
      hostID: tab.host.id,
      shellLabel: shellLabel,
      openWorkspace: { _ in },
      reconnect: { [weak tab] in
        guard let tab else { throw CancellationError() }
        return try await reconnect(host: tab.host)
      }
    )
  }

  /// Only the tab in front copies a frame, and only while the app is in
  /// front. The others stay subscribed, so the next time they are shown
  /// the screen they copy is the current one.
  private func refreshFramePublishing() {
    let foreground = phase != .background
    for tab in tabs.tabs {
      tab.setPublishesFrames(foreground && tab.id == tabs.selected)
      if foreground {
        tab.resumeReading()
      } else {
        tab.pauseReading()
      }
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
    tab.attach(plugin.attach(to: tabContext(for: tab, plugin: pluginID)), for: pluginID)
  }

  private func tabContext(for tab: SessionTab, plugin pluginID: String) -> TabContext {
    let id = tab.id
    return TabContext(
      id: id,
      plugin: pluginContext(for: tab),
      terminalName: { [weak tab] in tab?.terminalName },
      focus: { tabs.select(id) },
      dismissAccessory: { if tabs.accessory?.tab == id { tabs.accessory = nil } },
      present: { view in tabs.sheet = PluginSheet(tab: id, plugin: pluginID, view: view) },
      dismissSheet: { if tabs.sheet?.tab == id { tabs.sheet = nil } },
      insertText: { [weak tab] text in tab?.send(.paste(text)) },
      runInTerminal: { [weak tab] line in
        tab?.send(.paste(line))
        tab?.send(.key(.enter))
      },
      workingDirectory: { [weak tab] in tab?.workingDirectory },
      showAccessory: { tabs.showAccessory(pluginID, on: id) },
      linkActions: { [weak tab] pointed in tab.flatMap { linkActions(for: pointed, on: $0) } },
      shells: {
        tabs.visibleTabs.map { ShellChoice(id: $0.id, title: $0.title, current: $0.id == tabs.selected) }
      },
      openShell: { tabs.select($0) },
      newShell: { tabs.intent = .newTerminal },
      scrollBy: { [weak tab] lines in tab?.scrollOwnHistory(by: lines) },
      reportWheel: { [weak tab] lines, column, row in
        guard let tab, lines != 0 else { return }
        let button: PointerButton = lines > 0 ? .wheelUp : .wheelDown
        let count = min(Int(lines.magnitude), 500)
        for _ in 0..<count {
          tab.send(.pointer(button: button, phase: .press, column: column, row: row))
        }
      })
  }

  /// What pointing at the terminal does on this tab: whatever its plugins
  /// offer, read relative to where the tab's shell said it was.
  private func links(for tab: SessionTab) -> TerminalLinks {
    TerminalLinks(
      find: { [weak tab] row, column in tab?.link(atRow: row, column: column) },
      actions: { [weak tab] link in
        guard let tab else { return nil }
        return linkActions(
          for: PointedLink(link: link, directory: { [weak tab] in tab?.workingDirectory }),
          on: tab)
      })
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
        hostLabel: host?.label ?? "",
        hostID: host?.id ?? UUID(),
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

  func body(content: Content) -> some View {
    content.sheet(item: $tabs.sheet) { sheet in
      sheet.view
    }
  }
}

#if os(iOS)
private struct HostManagementNavigation: ViewModifier {
  func body(content: Content) -> some View {
    NavigationStack { content }
  }
}
#endif
