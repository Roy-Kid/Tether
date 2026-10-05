import SwiftUI
#if os(macOS)
  import AppKit
#endif
import TetherPluginKit
import TetherUI
#if os(macOS)
#endif

#if os(macOS)
  import AppKit
#endif

/// The same tabs in the titlebar or in a column beside the terminal.
struct WorkspaceTabBar: View {
  @Bindable var tabs: TabSet
  var layout: TabLayout = .horizontal
  var onClose: (UUID) -> Void
  /// The chip the pointer is over. A close box on every tab at once is a
  /// row of crosses; one that only appears under the pointer is a tab
  /// strip with a way to close a tab.
  @State private var hovering: UUID?
  @Environment(\.colorScheme) private var scheme
  @AppStorage("terminalAppearance") private var appearance = "system"

  /// Same choice the grid draws with, so the open tab is the top of that surface.
  private var palette: TetherUI.Palette {
    TetherUI.Palette.chosen(setting: appearance, scheme: scheme)
  }

  @ViewBuilder
  var body: some View {
    if layout == .vertical {
      tabList
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
    } else {
      titlebar
    }
  }

  private var titlebar: some View {
    HStack(spacing: 0) {
      Color.clear.frame(width: Chrome.trafficLights)
      TabBarToggle(tabs: tabs)
      tabList
      Spacer(minLength: 12)
        .background { WindowDragArea() }
    }
    .frame(height: Chrome.tab)
    .background(Theme.sidebar)
    // Behind the chips, so an open terminal tab can cover it and continue
    // into the grid. An overlay would paint the line back on top.
    .background(alignment: .bottom) { Divider() }
  }

  /// A terminal tab shares the grid's colour. An extension does not: its
  /// page is the window, and the accent rule is what marks it open.
  private func joinsTerminal(_ id: UUID) -> Bool {
    tabs.tabs.contains { $0.id == id && $0.shown == nil }
  }

  private var tabList: some View {
    ScrollViewReader { proxy in
      ScrollView(layout == .vertical ? .vertical : .horizontal) {
        let stack = layout == .vertical
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
          : AnyLayout(HStackLayout(spacing: 0))
        stack {
          ForEach(tabs.visibleTabs) { tab in
            tabChip(id: tab.id, title: tab.title, subtitle: tab.subtitle, symbol: nil)
              .id(tab.id)
          }
          ForEach(tabs.visibleExtensions) { entry in
            tabChip(
              id: entry.id, title: entry.workspace.title,
              subtitle: entry.workspace.subtitle, symbol: entry.workspace.symbol)
              .id(entry.id)
          }
        }
      }
      .scrollIndicators(.hidden)
      .onChange(of: tabs.selected, initial: true) { _, id in
        if let id { proxy.scrollTo(id, anchor: .center) }
      }
    }
  }

  private func tabChip(id: UUID, title: String, subtitle: String, symbol: String?) -> some View {
    let selected = tabs.selected == id
    let joined = selected && joinsTerminal(id)
    let tab = tabs.tabs.first { $0.id == id }
    let titleColor = joined ? palette.foreground : (selected ? Theme.text : Theme.subtle)
    let secondary = joined ? palette.foreground.opacity(0.62) : Theme.subtle
    return HStack(spacing: UIStyle.Space.inline) {
      Button {
        tabs.handleTabClick(id)
      } label: {
        HStack(spacing: UIStyle.Space.inline) {
          if let symbol {
            Image(systemName: symbol)
              .font(UIStyle.symbol)
              .foregroundStyle(titleColor)
          }
          let labels = layout == .vertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: UIStyle.Space.inline))
          labels {
            Text(title)
              .font(UIStyle.title)
              .foregroundStyle(titleColor)
              .lineLimit(1)
            if !subtitle.isEmpty {
              Text(subtitle)
                .font(UIStyle.header)
                .foregroundStyle(secondary)
                .lineLimit(1)
            }
          }
        }
        .frame(maxWidth: layout == .vertical ? .infinity : Chrome.tabTitleWidth,
               alignment: layout == .vertical ? .leading : .center)
        .frame(height: Chrome.tab)
        .contentShape(Rectangle())
      }
      .buttonStyle(ChromeButtonStyle())
      .help(subtitle.isEmpty ? title : "\(title) · \(subtitle)")
      .accessibilityAddTraits(selected ? .isSelected : [])
      // The space is held whether or not the cross is drawn: a tab that
      // grew by 18pt under the pointer would push the strip along.
      Button {
        onClose(id)
      } label: {
        Image(systemName: "xmark")
          .font(UIStyle.accessory)
          .foregroundStyle(secondary)
          .frame(width: UIStyle.Mark.icon, height: Chrome.tab)
          .contentShape(Rectangle())
      }
      .buttonStyle(ChromeButtonStyle())
      .opacity(selected || hovering == id ? 1 : 0)
      .allowsHitTesting(selected || hovering == id)
      .accessibilityHidden(!(selected || hovering == id))
      .help("Close tab")
      .accessibilityLabel("Close \(title)")
    }
    .padding(.leading, UIStyle.panelRadius)
    .padding(.trailing, UIStyle.Space.small)
    .frame(height: Chrome.tab)
    .background(joined ? palette.background : (selected ? Theme.raised.opacity(0.85) : Color.clear))
    .onHover { inside in
      if inside {
        hovering = id
      } else if hovering == id {
        hovering = nil
      }
    }
    .overlay(alignment: layout == .vertical ? .leading : .bottom) {
      if selected && !joined {
        Rectangle()
          .fill(Color.accentColor)
          .frame(
            width: layout == .vertical ? UIStyle.Mark.rule : nil,
            height: layout == .vertical ? nil : UIStyle.Mark.rule)
      }
    }
    .accessibilityAddTraits(selected ? .isSelected : [])
    .contextMenu {
      if let tab = tabs.tabs.first(where: { $0.id == id }) {
        // A picker has no icon of its own. The tab's menu is how it opens.
        let pickers = tabs.accessories.filter { $0.accessory.placement == .popover }
        if !pickers.isEmpty {
          ForEach(pickers) { plugin in
            Button(plugin.accessory.name) {
              tabs.toggleAccessory(plugin.id, on: id)
            }
            .disabled(!tab.canOpen(plugin.id))
          }
          Divider()
        }
        Button("Rename…") { tabs.renaming = id }
      }
      Button("Close Tab") { onClose(id) }
    }
    .popover(
      isPresented: Binding(
        get: { tabs.accessory?.tab == id },
        set: { if !$0 && tabs.accessory?.tab == id { tabs.accessory = nil } }
      ), arrowEdge: layout == .vertical ? .trailing : .bottom
    ) {
      if let tab, let open = tabs.accessory, let attachment = tab.attachment(for: open.plugin) {
        attachment.accessoryContent()
      }
    }
    #if os(macOS)
      .overlay {
        MiddleClickMonitor { onClose(id) }
          .allowsHitTesting(false)
      }
    #endif
  }
}

struct TabBarToggle: View {
  @Bindable var tabs: TabSet

  var body: some View {
    let title = tabs.title(for: .toggleTabBar)
    let shortcut = tabs.keyBindings.summary(for: WorkspaceAction.toggleTabBar.command)
    Button { tabs.perform(.toggleTabBar) } label: {
      Image(systemName: "sidebar.left")
        .font(UIStyle.symbol)
        .foregroundStyle(tabs.showsTabBar ? Color.accentColor : Theme.subtle)
        .frame(width: Chrome.tab, height: Chrome.tab)
        .contentShape(Rectangle())
    }
    .buttonStyle(ChromeButtonStyle())
    .help(shortcut.isEmpty ? title : "\(title) (\(shortcut))")
    .accessibilityLabel(title)
    .accessibilityValue(tabs.showsTabBar ? "Shown" : "Hidden")
  }
}

#if os(macOS)
/// Watches only the tab's bounds for a middle-button press; ordinary clicks
/// continue to reach the SwiftUI tab button underneath.
private struct MiddleClickMonitor: NSViewRepresentable {
  let action: () -> Void

  func makeNSView(context: Context) -> MiddleClickRegion {
    let view = MiddleClickRegion()
    view.action = action
    return view
  }

  func updateNSView(_ view: MiddleClickRegion, context: Context) {
    view.action = action
  }

  final class MiddleClickRegion: NSView {
    var action: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
        guard event.buttonNumber == 2, let self, event.window === self.window else { return event }
        let point = self.convert(event.locationInWindow, from: nil)
        guard self.bounds.contains(point) else { return event }
        self.action?()
        return nil
      }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
#endif

/// 24pt host switcher and connection status.
///
/// The host control leads. Settings is the same kind of control on the
/// trailing edge, and it opens the preferences window ⌘, already uses —
/// a second copy of that window would be two answers to one shortcut.
struct HostStatusBar: View {
  @Bindable var tabs: TabSet
  let store: HostStore
  let pluginStatusItems: [PluginStatusBarItem]
  var statusBarLabel: (String) -> AnyView? = { _ in nil }
  var statusBarSettings: (String) -> (() -> Void)? = { _ in nil }
  let makeStatusWorkspace: (String) -> (any PluginWorkspace)?

  var body: some View {
    HStack(spacing: UIStyle.Space.group) {
      Button {
        tabs.hostPicker.toggle()
      } label: {
        HStack(spacing: UIStyle.Space.inline) {
          if tabs.currentHost == nil {
            Image(systemName: "server.rack")
              .font(UIStyle.symbol)
              .foregroundStyle(Theme.subtle)
          } else {
            Circle()
              .fill(statusColor)
              .frame(width: UIStyle.Mark.presence, height: UIStyle.Mark.presence)
            Text(hostLabel)
              .font(UIStyle.detail)
              .foregroundStyle(Theme.text)
          }
          Image(systemName: "chevron.down")
            .font(UIStyle.accessory)
            .foregroundStyle(Theme.subtle)
        }
      }
      .buttonStyle(ChromeButtonStyle())
      .help(tabs.currentHost == nil ? "Choose host" : hostLabel)
      .accessibilityLabel("Host, \(hostLabel)")
      .accessibilityValue(statusDescription)

      ForEach(pluginStatusItems) { item in
        PluginStatusRibbon(
          item: item,
          label: statusBarLabel(item.id),
          openSettings: statusBarSettings(item.id)
        ) {
          makeStatusWorkspace(item.id)
        }
      }

      statusMark
      Spacer(minLength: 0)
      HStack(spacing: UIStyle.Space.tight) {
        ForEach(tabs.accessories.filter { $0.accessory.placement == .inspector }) { plugin in
          inspectorButton(plugin)
        }
        #if os(macOS)
          settingsButton
        #endif
      }
    }
    .padding(.horizontal, UIStyle.Space.inset)
    .frame(height: Chrome.status)
    .background(Theme.sidebar)
    .overlay(alignment: .top) { Divider() }
  }

  /// An inspector plugin, beside Settings on the trailing edge: one
  /// toggle for the column beside the terminal, not an icon on every tab.
  private func inspectorButton(_ plugin: PluginAccessory) -> some View {
    let showing = tabs.current != nil && tabs.isShowingInspector(of: plugin.id)
    return Button {
      guard let tab = tabs.current else { return }
      tabs.toggleAccessory(plugin.id, on: tab.id)
    } label: {
      Image(systemName: plugin.accessory.symbol)
        .font(UIStyle.symbol)
        .foregroundStyle(showing ? Color.accentColor : Theme.subtle)
        .frame(width: UIStyle.Mark.icon, height: Chrome.status)
        .contentShape(Rectangle())
    }
    .buttonStyle(ChromeButtonStyle())
    .disabled(tabs.current?.canOpen(plugin.id) != true)
    .help(plugin.accessory.name)
    .accessibilityLabel(plugin.accessory.name)
    .accessibilityValue(showing ? "Shown" : "Hidden")
  }

  private var hostLabel: String {
    guard let host = tabs.currentHost else { return "Choose host" }
    return host.label.isEmpty ? host.hostname : host.label
  }

  private var statusDescription: String {
    if tabs.currentExtension != nil { return "Connected" }
    guard let tab = tabs.current else { return "Not connected" }
    // What stands in for the shell speaks for the tab: the shell behind it
    // may have ended while what it shows, on another lease, is live.
    if let shown = tab.shown { return shown.isDisconnected ? "Disconnected" : "Connected" }
    switch tab.stage {
    case .connecting: return "Connecting"
    case .asking: return "Needs authentication"
    case .failed: return "Disconnected"
    case .ended: return "Ended"
    case .connected: return "Connected"
    }
  }

  private var statusColor: Color {
    if let shown = tabs.current?.shown {
      return shown.isDisconnected ? Theme.subtle : Theme.success
    }
    if tabs.current?.isLive == true || tabs.currentExtension != nil {
      return Theme.success
    }
    return Theme.subtle
  }

  @ViewBuilder
  private var statusMark: some View {
    if tabs.currentExtension != nil {
      EmptyView()
    } else if let tab = tabs.current {
      if let shown = tab.shown {
        if shown.isDisconnected { mark("bolt.slash", "Disconnected") }
      } else {
        switch tab.stage {
        case .connecting:
          ProgressView()
            .controlSize(.mini)
            .help("Connecting")
            .accessibilityLabel("Connecting")
        case .asking:
          mark("key.fill", "Needs authentication")
        case .failed:
          mark("bolt.slash", "Disconnected")
        case .ended:
          mark("stop.circle", "Ended")
        default:
          EmptyView()
        }
      }
    }
  }

  private func mark(_ symbol: String, _ name: String) -> some View {
    Image(systemName: symbol)
      .font(UIStyle.symbol)
      .foregroundStyle(Theme.subtle)
      .help(name)
      .accessibilityLabel(name)
  }

  #if os(macOS)
    private var settingsButton: some View {
      SettingsLink {
        Image(systemName: "gearshape")
          .font(UIStyle.symbol)
          .foregroundStyle(Theme.subtle)
          .frame(width: UIStyle.Mark.icon, height: Chrome.status)
          .contentShape(Rectangle())
      }
      .buttonStyle(ChromeButtonStyle())
      .help("Settings")
      .accessibilityLabel("Settings")
    }
  #endif
}

/// Anchored above the host bar, not a system popover — those clip at the window edge.
struct HostPicker: View {
  @Bindable var tabs: TabSet
  @Bindable var store: HostStore
  @State private var query = ""
  @State private var selection = PickerSelection<Host.ID>()
  @FocusState private var searchFocused: Bool

  var body: some View {
    let matches = filtered
    let grouping = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let connected = grouping ? connected(in: matches) : []
    let connectedIDs = Set(connected.map(\.id))
    let idle = matches.filter { !connectedIDs.contains($0.id) }
    let ordered = grouping ? connected + idle : matches
    VStack(alignment: .leading, spacing: UIStyle.Space.group) {
      TextField("Find a host…", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .onSubmit {
          if let host = ordered.first(where: { $0.id == selection.id }) { choose(host) }
        }
        .font(UIStyle.title)
        .padding(.horizontal, UIStyle.Space.group)
        .padding(.vertical, UIStyle.Space.inline)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))

      if let problem = store.problem {
        Text(problem).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }

      if matches.isEmpty {
        Text("No matching hosts.")
          .font(UIStyle.title)
          .foregroundStyle(Theme.subtle)
          .padding(.vertical, UIStyle.Space.small)
      }
      if matches.count > 8 {
        ScrollViewReader { proxy in
          ScrollView { list(ordered, connectedCount: connected.count) }
            .frame(maxHeight: UIStyle.listHeight)
            .scrollIndicators(.visible)
            .onChange(of: selection.id) { _, id in
              if let id { proxy.scrollTo(id) }
            }
        }
      } else {
        list(ordered, connectedCount: connected.count)
      }

      Divider()
      HStack(spacing: UIStyle.Space.tight) {
        Button {
          tabs.intent = .edit(.blank())
        } label: {
          Image(systemName: "plus")
            .font(UIStyle.symbol)
            .frame(width: UIStyle.controlHeight, height: UIStyle.controlHeight)
        }
        .help("Add host")
        .accessibilityLabel("Add host")

        Spacer()

        Button {
          tabs.hostPicker = false
          tabs.manageHosts = true
        } label: {
          Image(systemName: "list.bullet")
            .font(UIStyle.symbol)
            .frame(width: UIStyle.controlHeight, height: UIStyle.controlHeight)
        }
        .help("Manage hosts")
        .accessibilityLabel("Manage hosts")
      }
      .buttonStyle(ChromeButtonStyle())
      .foregroundStyle(Theme.subtle)
    }
    .padding(UIStyle.Space.inset)
    .frame(width: UIStyle.pickerWidth, alignment: .leading)
    .floatingPanel()
    .accessibilityAction(.escape) { tabs.hostPicker = false }
    .task {
      await Task.yield()
      guard !Task.isCancelled else { return }
      searchFocused = true
    }
    .onChange(of: ordered.map(\.id), initial: true) { _, ids in
      selection.reconcile(ids)
    }
    .onPickerCancel {
      tabs.hostPicker = false
    }
    .onPickerNavigation { movement in
      selection.navigate(movement, in: ordered.map(\.id))
    }
    .onPickerQuickSelection(count: ordered.count) { index in
      let hosts = ordered
      guard hosts.indices.contains(index) else { return }
      choose(hosts[index])
    }
  }

  private func choose(_ host: Host) {
    tabs.hostPicker = false
    if tabs.tabs.contains(where: { $0.host.id == host.id })
      || tabs.extensions.contains(where: { $0.hostID == host.id }) {
      tabs.show(host)
    } else {
      tabs.intent = .connect(host)
    }
  }

  private var filtered: [Host] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return store.listed }
    return store.listed.filter {
      $0.label.lowercased().contains(q)
        || $0.hostname.lowercased().contains(q)
        || $0.username.lowercased().contains(q)
    }
  }

  private func connected(in matches: [Host]) -> [Host] {
    let live = tabs.connectedHosts(in: matches)
    if let current = tabs.currentHost, matches.contains(where: { $0.id == current.id }) {
      return [current] + live.filter { $0.id != current.id }
    }
    return live
  }

  private func list(_ matches: [Host], connectedCount: Int) -> some View {
    VStack(alignment: .leading, spacing: UIStyle.Space.tight) {
      ForEach(Array(matches.enumerated()), id: \.element.id) { index, host in
        if index == connectedCount && connectedCount > 0 { Divider() }
        row(host, index: index)
      }
    }
  }

  private func row(_ host: Host, index: Int) -> some View {
    let current = tabs.currentHost?.id == host.id
    let live = tabs.isLive(host: host)
    return Button {
      choose(host)
    } label: {
      HStack(alignment: .center, spacing: UIStyle.Space.group) {
        Circle()
          .fill(live ? Theme.success : .clear)
          .frame(width: UIStyle.Mark.presence, height: UIStyle.Mark.presence)
        Text(host.label.isEmpty ? host.hostname : host.label)
          .font(UIStyle.title)
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        Spacer(minLength: 0)
        PickerShortcutHint(index: index)
        Image(systemName: "checkmark")
          .font(UIStyle.accessory)
          .foregroundStyle(current ? Theme.text : .clear)
          .frame(width: UIStyle.Mark.disclosure)
      }
      .padding(.horizontal, UIStyle.Space.inline)
      .padding(.vertical, UIStyle.rowPadding)
      .frame(minHeight: UIStyle.rowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(ChromeButtonStyle(selected: selection.id == host.id))
    .id(host.id)
    .accessibilityAddTraits(current ? .isSelected : [])
    .accessibilityValue(live ? "Connected" : "Not connected")
    .help(tabs.workspaceCaption(for: host))
  }
}

/// The host's row chrome behind a generic lamp. A plugin that draws its own
/// ribbon is already the control, and a second fill behind it stretches the row.
private struct RibbonButtonChrome: ViewModifier {
  let plain: Bool

  func body(content: Content) -> some View {
    if plain {
      content.buttonStyle(.plain)
    } else {
      content.buttonStyle(ChromeButtonStyle())
    }
  }
}

private struct StatusRibbonPopover: Identifiable {
  let id = UUID()
  let workspace: any PluginWorkspace
}

/// A status plugin's lamp: its own view when it draws one, otherwise its
/// segments as a ribbon. Clicking it opens the plugin's panel; right-click
/// reaches its settings.
private struct PluginStatusRibbon: View {
  let item: PluginStatusBarItem
  var label: AnyView? = nil
  var openSettings: (() -> Void)? = nil
  let makeWorkspace: () -> (any PluginWorkspace)?
  @State private var presentation: StatusRibbonPopover?
  @State private var isPresented = false

  var body: some View {
    Button {
      if isPresented {
        isPresented = false
      } else if let workspace = makeWorkspace() {
        presentation = StatusRibbonPopover(workspace: workspace)
        isPresented = true
      }
    } label: {
      if let label {
        label
      } else {
        StatusRibbon(segments: item.segments)
          .frame(width: Chrome.swatchWidth, height: Chrome.swatchHeight)
      }
    }
    .modifier(RibbonButtonChrome(plain: label != nil))
    .contextMenu {
      if let openSettings {
        Button("Settings…", action: openSettings)
      }
    }
    .accessibilityLabel(item.label)
    .help(item.label)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      if let presentation {
        presentation.workspace.content()
      }
    }
    .onChange(of: isPresented) { _, shown in
      if !shown {
        presentation?.workspace.close()
        presentation = nil
      }
    }
  }
}

struct EmptyWorkspace: View {
  var body: some View {
    QuietMark("No Open Terminals", systemImage: "terminal")
  }
}

#if os(macOS)
  /// Content draws under the traffic lights so the tab strip can be 36pt, not a second titlebar.
  struct CompactTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Hook)?.apply() }

    private final class Hook: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
      }

      func apply() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
      }
    }
  }

  /// Empty titlebar space that drags the window, including next to the tabs.
  struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
      override var mouseDownCanMoveWindow: Bool { true }
      override func hitTest(_ point: NSPoint) -> NSView? { self }
      override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
      }
    }
  }

  /// Preferences window chrome: traffic lights only, content under a clear
  /// titlebar. The page title lives in the detail pane, not the titlebar.
  struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Hook)?.apply() }

    private final class Hook: NSView {
      private var applying = false
      private var scheduled = false
      private var armedFrameMemory = false
      /// AppKit's frame key for `setFrameAutosaveName`. Read before the name
      /// is armed, so this launch's default size cannot replace the last one.
      private static let frameName = "Tether.Settings"

      deinit {
        NotificationCenter.default.removeObserver(self)
      }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
          NotificationCenter.default.addObserver(
            self, selector: #selector(windowChanged),
            name: NSWindow.didUpdateNotification, object: window)
        }
        apply()
        schedule()
        armFrameMemory()
      }

      /// Open at the size and place the window had when it last closed.
      /// The first launch keeps the scene's default size.
      private func armFrameMemory() {
        guard !armedFrameMemory, let window else { return }
        armedFrameMemory = true
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)")
        DispatchQueue.main.async { [weak window] in
          DispatchQueue.main.async {
            guard let window else { return }
            if let saved, let frame = Hook.frame(from: saved, for: window) {
              window.setFrame(frame, display: true)
            }
            window.setFrameAutosaveName(Self.frameName)
          }
        }
      }

      /// `setFrameAutosaveName` stores `x y width height` plus the screen,
      /// which `NSRectFromString` does not read.
      private static func frame(from saved: String, for window: NSWindow) -> NSRect? {
        let parts = saved.split(separator: " ").compactMap { Double($0) }
        let parsed: NSRect
        if parts.count >= 4 {
          parsed = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        } else {
          parsed = NSRectFromString(saved)
        }
        guard parsed.width >= 660, parsed.height >= 500,
          parsed.width < 10_000, parsed.height < 10_000
        else { return nil }
        guard let screen = window.screen ?? NSScreen.main else { return parsed }
        return window.constrainFrameRect(parsed, to: screen)
      }

      /// Sidebar selection makes the Settings scene show its title again.
      /// The detail page already has one.
      @objc private func windowChanged() {
        guard !applying, let window, window.titleVisibility != .hidden else { return }
        applying = true
        apply()
        applying = false
      }

      override func layout() {
        super.layout()
        guard !applying else { return }
        applying = true
        apply()
        applying = false
        schedule()
      }

      private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.scheduled = false
          self.apply()
        }
      }

      func apply() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.tabbingMode = .disallowed
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: Chrome.settingsMinWidth, height: Chrome.settingsMinHeight)
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        for item in window.toolbar?.items ?? [] {
          let label = item.label
          let identifier = item.itemIdentifier.rawValue
          if label.hasSuffix("Settings") || identifier.localizedCaseInsensitiveContains("title") {
            item.isHidden = true
          }
        }
        // Hide Sidebar does not fit beside the traffic lights, so AppKit clips
        // it into the overflow chevron at the top right. The sidebar stays put.
        removeSidebarToggle(from: window)
        if let frame = window.contentView?.superview {
          hideToolbarOverflow(in: frame)
        }
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
          hideSceneTitle(in: titlebar)
        }
      }

      private func removeSidebarToggle(from window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        let indexes = toolbar.items.indices.reversed().filter { index in
          toolbar.items[index].itemIdentifier.rawValue.hasSuffix("toggleSidebar")
        }
        for index in indexes {
          toolbar.removeItem(at: index)
        }
      }

      /// An empty clip menu still draws the chevron until the next layout.
      private func hideToolbarOverflow(in view: NSView) {
        let className = String(describing: type(of: view))
        let label = view.accessibilityLabel() ?? ""
        if className.contains("ClippedItems") || label == "more toolbar items" {
          view.isHidden = true
        }
        for subview in view.subviews {
          hideToolbarOverflow(in: subview)
        }
      }

      /// The Settings scene draws "Tether Settings" into the titlebar. The
      /// detail page already has that title.
      private func hideSceneTitle(in view: NSView) {
        if let text = view as? NSTextField, text.stringValue.hasSuffix("Settings") {
          text.isHidden = true
        }
        let label = view.accessibilityLabel() ?? ""
        let value = view.accessibilityValue() as? String ?? ""
        if view.subviews.isEmpty, label.hasSuffix("Settings") || value.hasSuffix("Settings") {
          view.isHidden = true
        }
        for subview in view.subviews { hideSceneTitle(in: subview) }
      }
    }
  }
#else
  struct CompactTitlebar: View {
    var body: some View { Color.clear }
  }
  struct WindowDragArea: View {
    var body: some View { Color.clear }
  }
#endif
