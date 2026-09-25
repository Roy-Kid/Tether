import SwiftUI

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
  @State private var connecting: Host?
  @State private var visibility: NavigationSplitViewVisibility = .all
  @State private var showingSettings = false
  @State private var renameDraft = ""
  @State private var reconnectID: UUID?
  @State private var reconnectAnswer: CheckedContinuation<String, Error>?
  /// A keychain that refused. Rare, and silence would be the wrong answer:
  /// a person who ticked "remember" would go on believing it was kept.
  @State private var keychainProblem: String?
  @AppStorage("appearance") private var appearance = "system"
  @Environment(\.openURL) private var openURL
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
      && !tabs.manageHosts && editing == nil && connecting == nil && !showingSettings
      && keychainProblem == nil
  }
  var body: some View {
    windowChrome
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
          if tabs.zen {
            Color.clear.frame(height: 28).background { WindowDragArea() }
          } else {
            WorkspaceTabBar(tabs: tabs, onClose: { tabs.requestClose($0) })
          }
          HSplitView {
            canvas
            // The inspector sits under the tab strip, not beside it in the
            // titlebar: its own header belongs to the column, in the same
            // row as the listing it controls (design 16-inspector).
            if showInspector {
              inspectorPane
                .frame(minWidth: Chrome.inspectorMin, idealWidth: Chrome.inspectorIdeal, maxWidth: 480)
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
            .padding(.leading, 10)
            .padding(.bottom, Chrome.status + 8)
        }
      }
      .background(Theme.window)
      .background { CompactTitlebar() }
      .ignoresSafeArea(.container, edges: .top)
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
  /// The sheet exists to collect a credential for a handshake. A shell on
  /// this machine has neither, so presenting it would be asking a person to
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
    if let issue = host.connectionProblem { keychainProblem = issue; return }
    do {
      if let connection = try await tabs.lease(for: host) {
        tabs.open(host, on: connection)
        return
      }
    } catch {
      // The in-flight handshake failed. Asking again is the remaining path.
    }
    let master = host.allowsMasterReuse ? await TerminalSession.sshMasterIsRunning(host.sshTarget) : false
    if master || host.offersConfiguredKey {
      tabs.open(host, password: "")
      return
    }
    if let password = remembered(for: host), !password.isEmpty {
      tabs.open(host, password: password)
      return
    }
    connecting = host
  }

  #if os(macOS)
  #endif

  private var canvas: some View {
    Group {
      if let workspace = extensionWorkspace {
        workspace.content().id(workspace.id)
      } else if let tab = tabs.current {
        if let shown = tab.shown {
          shown.content().id(tab.id)
        } else {
          SessionView(tab: tab, links: links(for: tab)).id(tab.id)
            .dropDestination(for: URL.self) { urls, _ in drop(urls, on: tab) }
        }
      } else if tabs.currentHost != nil {
        EmptyWorkspace()
      } else {
        welcome
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Chrome.margin)
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
          ContentUnavailableView("No workspace selected", systemImage: "sidebar.right")
        }
      }
    }
  #endif

  private var phoneDetail: some View {
    Group {
      if tabs.tabs.isEmpty && tabs.extensions.isEmpty {
        ContentUnavailableView("No Open Terminals", systemImage: "terminal")
      } else {
        TabView(selection: phoneTabSelection) {
          ForEach(tabs.tabs) { tab in
            phoneSession(tab)
              .tabItem { Label(tab.title, systemImage: "terminal") }
              .tag(Optional(tab.id))
          }
          ForEach(tabs.extensions) { entry in
            entry.workspace.content().id(entry.id)
              .terminalInputEnabled(terminalInputAllowed && tabs.selected == entry.id)
              .padding(Chrome.margin)
              .tabItem { Label(entry.workspace.title, systemImage: entry.workspace.symbol) }
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
        if let tab = tabs.current {
          ForEach(tabs.accessories) { plugin in
            Button(plugin.accessory.name, systemImage: plugin.accessory.symbol) {
              tabs.toggleAccessory(plugin.id, on: tab.id)
            }
            .labelStyle(.iconOnly)
            .disabled(!tab.canOpen(plugin.id))
          }
        }
        if let workspace = extensionWorkspace {
          ForEach(workspace.commands) { command in
            Button(command.title, systemImage: command.symbol, action: command.action)
              .labelStyle(.iconOnly)
          }
        }
        if let id = tabs.selected {
          Button("Close", systemImage: "xmark") { tabs.requestClose(id) }
            .labelStyle(.iconOnly)
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

  @ViewBuilder
  private func phoneSession(_ tab: SessionTab) -> some View {
    Group {
      if let shown = tab.shown {
        shown.content()
      } else {
        SessionView(tab: tab)
      }
    }
    .id(tab.id)
    .terminalInputEnabled(terminalInputAllowed && tabs.selected == tab.id)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Chrome.margin)
  }
}

extension RootView {
  /// Everything that belongs to the window rather than to either column.
  @ViewBuilder
  fileprivate var windowChrome: some View {
    container
    .terminalInputEnabled(terminalInputAllowed)
    .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    .overlay {
      PaletteOverlay(
        tabs: tabs, store: store, commands: commandItems, onPickHost: open)
    }
    #if os(macOS)
      .background {
        Button("Command Menu") { tabs.openPalette(.command) }
          .keyboardShortcut("p", modifiers: [.control, .shift])
          .hidden()
      }
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
    .onChange(of: registry.disabled, initial: true) { _, _ in
      tabs.accessories = registry.plugins.compactMap { plugin in
        guard let plugin = plugin as? any TabPlugin, registry.isEnabled(plugin.metadata.id)
        else { return nil }
        return PluginAccessory(
          id: plugin.metadata.id, title: plugin.metadata.name, accessory: plugin.accessory)
      }
    }
    // On a Mac the accessory is a popover, so the window can present this.
    // A phone's accessory is a sheet, and a sheet's ancestor cannot present a
    // second one over it — so there it is presented from inside that sheet.
    #if os(macOS)
      .modifier(PluginSheetPresentation(tabs: tabs))
    #endif
    .onChange(of: tabs.intent) { _, intent in
      guard let intent else { return }
      tabs.intent = nil
      switch intent {
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
        .frame(minWidth: 420, minHeight: 480)
      #else
        .modifier(HostManagementNavigation())
      #endif
    }
    .alert(
      tabs.closeQuestion,
      isPresented: Binding(
        get: { tabs.pendingClose != nil },
        set: { if !$0 { tabs.pendingClose = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { tabs.pendingClose = nil }
      Button("Close", role: .destructive) { tabs.confirmClose() }
    } message: {
      if let note = tabs.closeNote {
        Text(note)
      }
    }
    .alert(
      "Rename",
      isPresented: Binding(
        get: { tabs.renaming != nil },
        set: { if !$0 { tabs.renaming = nil } }
      )
    ) {
      TextField("Name", text: $renameDraft)
      Button("Cancel", role: .cancel) { tabs.renaming = nil }
      Button("Save") {
        if let id = tabs.renaming { tabs.rename(id, to: renameDraft) }
      }
    }
    .onChange(of: tabs.renaming) { _, id in
      renameDraft = tabs.tabs.first { $0.id == id }?.name ?? ""
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
    .sheet(
      item: $connecting,
      onDismiss: {
        reconnectAnswer?.resume(throwing: CancellationError())
        reconnectAnswer = nil
      }
    ) { host in
      ConnectSheet(host: host, remembered: remembered(for: host)) { password, remember in
        keep(password, remember: remember, for: host)
        if let answer = reconnectAnswer {
          reconnectAnswer = nil
          answer.resume(returning: password)
        } else {
          tabs.open(host, password: password)
        }
      }
    }
    // Closing every session on the way out is not tidiness: each one holds a
    // socket and a task, and the far side is owed a disconnect rather than a
    // dropped connection. The notification is named differently on each
    // platform, and a phone can be killed without sending it at all — which
    // is why the sessions also close on `deinit`, not only here.
    .onReceive(NotificationCenter.default.publisher(for: terminationNotification)) { _ in
      tabs.closeAll()
    }
    .onAppear { registry.onDisable = { id in tabs.closePlugin(id) } }
    .alert(
      "The password was not saved",
      isPresented: Binding(get: { keychainProblem != nil }, set: { if !$0 { keychainProblem = nil } })
    ) {
      Button("OK", role: .cancel) { keychainProblem = nil }
    } message: {
      Text(keychainProblem ?? "")
    }
  }

  private var commandItems: [CommandItem] {
    var items: [CommandItem] = [
      CommandItem(id: "new", title: "New Terminal", detail: "File", enabled: true) {
        tabs.intent = .newTerminal
        tabs.palette = nil
      },
      CommandItem(id: "host", title: "Change Host…", detail: "File", enabled: true) {
        tabs.palette = nil
        tabs.hostPicker = true
      },
      CommandItem(
        id: "close", title: "Close Tab", detail: "File", enabled: tabs.selected != nil
      ) {
        tabs.palette = nil
        tabs.requestCloseSelected()
      },
      CommandItem(
        id: "zen", title: tabs.zen ? "Exit Zen Mode" : "Zen Mode", detail: "View · ⌘⇧Z",
        enabled: true
      ) {
        tabs.palette = nil
        tabs.toggleZen()
      },
      CommandItem(
        id: "rename", title: "Rename Terminal", detail: "Terminal", enabled: tabs.current != nil
      ) {
        tabs.palette = nil
        tabs.renaming = tabs.current?.id
      },
    ]
    #if os(macOS)
      // The inspector is a second column in a window; a phone has neither.
      items.append(
        CommandItem(id: "inspector", title: "Inspector", detail: "View", enabled: !tabs.zen) {
          tabs.palette = nil
          tabs.toggleInspector()
        })
    #endif
    items += registry.plugins
      .filter { registry.isEnabled($0.metadata.id) && !$0.isStatusBarOnly }
      .map { plugin in
      let blocked =
        plugin is any TabPlugin
        ? tabs.current?.canOpen(plugin.metadata.id) != true
        : plugin.needsRemoteConnection && tabs.current?.connection == nil
      return CommandItem(
        id: "plugin-\(plugin.metadata.id)", title: plugin.metadata.name,
        detail: plugin.metadata.summary, enabled: !blocked
      ) {
        tabs.palette = nil
        launch(plugin)
      }
    }
    return items
  }


  /// What the keychain already has for this host, if the person asked for it
  /// to be kept. Read at the moment of connecting, not held in memory: a
  /// password sitting in a view model is a password in a crash report.
  private func remembered(for host: Host) -> String? {
    guard host.remembersPassword else { return nil }
    return try? secrets.password(for: host.passwordID)
  }

  /// Records or clears what a person asked to be remembered.
  ///
  /// The flag on the host and the item in the keychain are two facts that
  /// must agree: a host marked as remembering with nothing stored prefills
  /// an empty field for ever, so a keychain that refuses leaves the flag off.
  private func keep(_ password: String, remember: Bool, for host: Host) {
    if host.isManaged {
      if !store.save(host, password: remember ? password : "") { keychainProblem = store.problem }
      return
    }
    var updated = host
    updated.remembersPassword = remember
    do {
      if remember {
        try secrets.remember(password, for: host)
      } else {
        try secrets.forget(host.id)
      }
    } catch {
      keychainProblem = error.localizedDescription
      updated.remembersPassword = false
    }

    // Only a host that is actually saved: this sheet also opens for a
    // reconnect, and a host deleted in the meantime must not come back.
    guard updated.remembersPassword != host.remembersPassword,
      store.hosts.contains(where: { $0.id == host.id })
    else { return }
    store.save(updated)
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
      reconnect: { try await reconnect(host: tab.host) }
    )
  }

  /// Makes the tab's attachment for this plugin the first time its
  /// accessory opens there, and hands an existing one the tab's current
  /// lease — which a reconnect may have replaced since.
  private func prepareAttachment(_ pluginID: String, on tab: SessionTab) {
    if let attachment = tab.attachment(for: pluginID) {
      if let connection = tab.connection { attachment.connectionChanged(connection) }
      return
    }
    guard tab.connection != nil else { return }
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
      terminalName: tab.terminalName,
      focus: { tabs.select(id) },
      dismissAccessory: { if tabs.accessory?.tab == id { tabs.accessory = nil } },
      present: { view in tabs.sheet = PluginSheet(tab: id, plugin: pluginID, view: view) },
      dismissSheet: { if tabs.sheet?.tab == id { tabs.sheet = nil } },
      insertText: { [weak tab] text in tab?.send(.paste(text)) },
      workingDirectory: { [weak tab] in tab?.workingDirectory },
      showAccessory: { tabs.showAccessory(pluginID, on: id) },
      linkActions: { [weak tab] pointed in tab.flatMap { linkActions(for: pointed, on: $0) } })
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

  /// Files dropped on a terminal.
  ///
  /// On this machine a terminal types their paths, which is what every
  /// terminal does and all a local shell needs. Anywhere else a local path
  /// means nothing, so the tab's plugins are offered them — the first to
  /// take them decides what a drop means there.
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
    if let connection = try? await tabs.lease(for: host) {
      return connection
    }
    let requestID = UUID()
    let password: String
    let master = host.allowsMasterReuse ? await TerminalSession.sshMasterIsRunning(host.sshTarget) : false
    if host.isLocal || host.offersConfiguredKey || master {
      password = ""
    } else {
      password = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          reconnectAnswer?.resume(throwing: CancellationError())
          reconnectID = requestID
          reconnectAnswer = continuation
          connecting = host
        }
      } onCancel: {
        Task { @MainActor in
          if reconnectID == requestID {
            reconnectAnswer?.resume(throwing: CancellationError())
            reconnectAnswer = nil
            connecting = nil
          }
        }
      }
    }
    let selected = tabs.selected
    tabs.open(host, password: password)
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
