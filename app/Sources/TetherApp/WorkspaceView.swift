import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif
import Tether
import TetherPluginKit

struct WorkspaceEntry: Identifiable {
  let pluginID: String
  let workspace: any PluginWorkspace
  var id: UUID { workspace.id }
}

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
  @State private var editing: Host?
  @State private var connecting: Host?
  @State private var visibility: NavigationSplitViewVisibility = .all
  @State private var inspector = false
  @State private var showingSettings = false
  @State private var reconnectID: UUID?
  @State private var reconnectAnswer: CheckedContinuation<String, Error>?
  @AppStorage("appearance") private var appearance = "system"
  #if !os(macOS)
    /// Whether there is room for two columns. A phone in portrait is compact;
    /// an iPad, and a phone turned sideways, are not.
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  private var extensionWorkspace: (any PluginWorkspace)? {
    tabs.extensions.first { $0.id == tabs.selected }?.workspace
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
      splitView
    #else
      if sizeClass == .compact {
        NavigationStack {
          sidebar
            .navigationDestination(item: $tabs.selected) { _ in
              detail.navigationBarTitleDisplayMode(.inline)
            }
        }
      } else {
        splitView
      }
    #endif
  }

  private var splitView: some View {
    NavigationSplitView(columnVisibility: $visibility) {
      sidebar
    } detail: {
      detail
    }
  }

  private var sidebar: some View {
    Sidebar(
      store: store,
      onOpen: { connecting = $0 }, onEdit: { editing = $0 }, onNew: { editing = .blank() },
      onSettings: { showingSettings = true }
    )
    .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
  }

  private var detail: some View {
      VStack(spacing: 0) {
        if !tabs.tabs.isEmpty || !tabs.extensions.isEmpty {
          tabStrip
          Divider()
        }
        if let workspace = extensionWorkspace {
          workspace.content().id(workspace.id)
        } else if let tab = tabs.current {
          SessionView(tab: tab).id(tab.id)
        } else {
          welcome
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(extensionWorkspace?.title ?? tabs.current?.title ?? "Tether")
      #if os(macOS)
        .navigationSubtitle(
          extensionWorkspace?.subtitle ?? tabs.current?.host.address ?? "Your remote workspace"
        )
      #endif
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          // Icon-only throughout, with the name in the tooltip. A toolbar
          // that grows a word per extension stops being a toolbar.
          if let workspace = extensionWorkspace {
            ForEach(workspace.commands) { command in
              Button(command.title, systemImage: command.symbol, action: command.action)
                .labelStyle(.iconOnly)
                .help(command.title)
            }
          } else {
            // This is where an enabled extension shows up: as its own button,
            // in the window, next to the work. Turning it on in Settings is
            // the only other place it is ever named.
            ForEach(
              registry.plugins.filter { registry.isEnabled($0.metadata.id) }, id: \.metadata.id
            ) { plugin in
              Button(plugin.metadata.name, systemImage: plugin.metadata.symbol) { launch(plugin) }
                .labelStyle(.iconOnly)
                .disabled(tabs.current?.connection == nil)
                .help(
                  tabs.current?.connection == nil
                    ? "\(plugin.metadata.name) — connect to a host first"
                    : plugin.metadata.summary)
            }
          }
          Button("Inspector", systemImage: "sidebar.right") { inspector.toggle() }
            .labelStyle(.iconOnly)
            .help(inspector ? "Hide inspector" : "Show inspector")
        }
      }
      .inspector(isPresented: $inspector) {
        Group {
          if let workspace = extensionWorkspace {
            workspace.inspector()
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
        }.inspectorColumnWidth(min: 240, ideal: 280, max: 360)
      }
  }
}

extension RootView {
  /// Everything that belongs to the window rather than to either column.
  @ViewBuilder
  fileprivate var windowChrome: some View {
    container
    .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    .sheet(item: $editing) { host in HostEditor(host: host) { store.save($0) } }
    #if !os(macOS)
      .sheet(isPresented: $showingSettings) {
        NavigationStack {
          AppSettings(registry: registry)
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
      ConnectSheet(host: host) { password in
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
  }
  private func launch(_ plugin: any TetherPlugin) {
    guard let tab = tabs.current, let connection = tab.connection else { return }
    let host = tab.host
    plugin.launch(
      in: PluginContext(
        connection: connection, hostLabel: host.label, hostID: host.id,
        openWorkspace: { workspace in
          tabs.extensions.append(WorkspaceEntry(pluginID: plugin.metadata.id, workspace: workspace))
          tabs.selected = workspace.id
        },
        reconnect: {
          let requestID = UUID()
          let password: String = try await withTaskCancellationHandler {
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
        }))
  }
  private var welcome: some View {
    VStack(spacing: 20) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.tint)
        .padding(.bottom, 4)
      VStack(spacing: 8) {
        Text("A place for your remote work.").font(.system(size: 28, weight: .semibold))
        Text(
          store.hosts.isEmpty
            ? "Add a host. Open a terminal. Make yourself at home."
            : "Choose a host in the sidebar to open a secure connection."
        )
        .font(.body).foregroundStyle(.secondary)
      }
      Button("Add host", systemImage: "plus") { editing = .blank() }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .help("Add host")
      HStack(spacing: 22) {
        Label("Secure connections", systemImage: "lock.shield")
        Label("Extensible workspaces", systemImage: "puzzlepiece.extension")
      }.font(.caption).foregroundStyle(.secondary).padding(.top, 16)
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
  }
  private var tabStrip: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 4) {
        ForEach(tabs.tabs) { tab in chip(id: tab.id, title: tab.title, symbol: "terminal") }
        ForEach(tabs.extensions) { entry in
          chip(id: entry.id, title: entry.workspace.title, symbol: entry.workspace.symbol)
        }
      }.padding(8)
    }.scrollIndicators(.hidden).frame(height: 48).background(.bar)
  }
  private func chip(id: UUID, title: String, symbol: String) -> some View {
    HStack(spacing: 8) {
      Button {
        tabs.selected = id
      } label: {
        Label(title, systemImage: symbol).lineLimit(1).frame(maxWidth: 180)
      }.buttonStyle(.plain)
      Button {
        tabs.close(id)
      } label: {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.plain).foregroundStyle(.secondary)
      .accessibilityLabel("Close \(title)")
      .help("Close \(title)")
    }.font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
      .background(
        tabs.selected == id ? Color.accentColor.opacity(0.12) : .clear,
        in: RoundedRectangle(cornerRadius: 9)
      )
      .accessibilityAddTraits(tabs.selected == id ? .isSelected : [])
  }
}

struct FilledButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.body.weight(.medium)).foregroundStyle(.white)
      .padding(.horizontal, 16).padding(.vertical, 8)
      .background(
        Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1),
        in: RoundedRectangle(cornerRadius: 8))
  }
}
