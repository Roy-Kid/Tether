import SwiftUI
import Observation
import TetherPluginKit
import TetherUI

/// Adapts an installed manifest to the same UI contract as built-in extensions.
@MainActor @Observable
public final class WebPlugin: TetherPlugin {
  public let record: PluginRecord
  private let host: PluginHost
  private var background: UUID?
  private var starting: Task<Void, Never>?
  private var workspaces: [UUID: WebPluginWorkspace] = [:]
  private var enabled = false
  public private(set) var statusBarItem: PluginStatusBarItem?
  private var indicatorSessions: [UUID: [PluginTabIndicator]] = [:]
  public var tabIndicators: [PluginTabIndicator] {
    indicatorSessions.keys.sorted { $0.uuidString < $1.uuidString }
      .flatMap { indicatorSessions[$0] ?? [] }
  }
  func receiveTabIndicators(_ items: [PluginTabIndicator], session: UUID) {
    indicatorSessions[session] = items.isEmpty ? nil : items
  }

  public init(record: PluginRecord, host: PluginHost) {
    self.record = record
    self.host = host
  }
  public var metadata: PluginMetadata {
    PluginMetadata(id: record.id, name: record.manifest.name,
                   symbol: "puzzlepiece.extension", summary: "\(record.manifest.publisher) · \(record.manifest.version)")
  }
  public var needsRemoteConnection: Bool { false }

  /// Right-click Settings… and the Extensions row both open the native window.
  /// The page does not get a second preferences form.
  public func statusBarSettings() -> (() -> Void)? {
    guard let url = record.manifest.settingsURL else { return nil }
    return { HostLinks.open(url) }
  }

  public func settings() -> AnyView {
    guard let url = record.manifest.settingsURL else {
      return AnyView(Text("No additional settings"))
    }
    return AnyView(NativeSettingsLink(name: record.manifest.name, url: url))
  }
  public var isStatusBarOnly: Bool {
    record.manifest.contributions.allSatisfy { $0.kind == .statusBar }
  }

  public func activate() {
    guard !enabled else { return }
    enabled = true
    try? host.setEnabled(true, id: record.id)
    guard record.manifest.contributions.contains(where: { $0.kind == .statusBar || $0.kind == .tabIndicator }) else { return }
    if record.manifest.contributions.contains(where: { $0.kind == .statusBar }) {
      statusBarItem = PluginStatusBarItem(id: record.id, label: record.manifest.name, segments: [])
    }
    starting = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let session = try await host.activate(id: record.id, runtime: WebKitRuntime(background: true))
        guard enabled, !Task.isCancelled else { host.unload(session: session); return }
        background = session
      } catch {
        // The panel says why, when someone opens it. The host does not banner this.
      }
    }
  }

  public func deactivate() {
    enabled = false
    starting?.cancel()
    starting = nil
    for workspace in Array(workspaces.values) { workspace.close() }
    workspaces.removeAll()
    try? host.setEnabled(false, id: record.id)
    background = nil
    statusBarItem = nil
    indicatorSessions.removeAll()
  }

  public func launch(in context: PluginContext) {
    guard enabled else { return }
    let reconnect = context.reconnect
    context.openWorkspace(makeWorkspace(environment: context.environment, reconnect: {
      _ = try await reconnect()
    }))
  }
  public func statusBarWorkspace() -> (any PluginWorkspace)? {
    enabled ? makeWorkspace(compact: true) : nil
  }
  /// The sentence the open panel shows when this plugin cannot start.
  func activationFailure(in workspace: any PluginWorkspace) -> String? {
    (workspace as? WebPluginWorkspace)?.failure
  }

  public func receiveStatus(_ item: PluginStatusBarItem) {
    guard enabled, item != statusBarItem else { return }
    statusBarItem = item
  }
  private func makeWorkspace(
    environment: PluginEnvironment = .none, reconnect: (@MainActor () async throws -> Void)? = nil,
    compact: Bool = false
  ) -> WebPluginWorkspace {
    let workspace = WebPluginWorkspace(
      record: record, host: host, environment: environment, reconnect: reconnect, compact: compact
    ) { [weak self] id in
      self?.workspaces[id] = nil
    }
    workspaces[workspace.id] = workspace
    return workspace
  }

  func receiveStatus(_ payload: JSONValue) {
    guard enabled, case .array(let raw) = payload.key("segments"), raw.count <= 32 else { return }
    var segments: [PluginStatusSegment] = []
    for (index, value) in raw.enumerated() {
      guard case .number(let color) = value.key("color"), color.isFinite,
        color >= 0, color <= 0xFFFFFF, color.rounded() == color,
        case .number(let weight) = value.key("weight"), weight.isFinite, weight >= 0 else { return }
      segments.append(PluginStatusSegment(id: String(index), color: UInt32(color), weight: weight))
    }
    let label = String((payload.key("label")?.string ?? record.manifest.name).prefix(256))
    receiveStatus(PluginStatusBarItem(id: record.id, label: label, segments: segments))
  }
}

/// One control. Clicking it leaves Tether and opens the app that owns the URL.
private struct NativeSettingsLink: View {
  let name: String
  let url: URL

  var body: some View {
    Button {
      HostLinks.open(url)
    } label: {
      Label("Open \(name) Settings", systemImage: "gearshape")
    }
    .help("Opens the \(name) settings window")
  }
}

@MainActor @Observable
private final class WebPluginWorkspace: PluginWorkspace {
  let id = UUID()
  private let record: PluginRecord
  private let host: PluginHost
  private let runtime = WebKitRuntime()
  private var session: UUID?
  private var starting: Task<Void, Never>?
  private var closed = false
  private let compact: Bool
  private let environment: PluginEnvironment
  private let reconnect: (@MainActor () async throws -> Void)?
  private let onClose: (UUID) -> Void
  /// Why this panel has no page. Nil while it is loading or showing one.
  fileprivate var failure: String?
  var title: String { record.manifest.name }
  var subtitle: String { "" }
  var symbol: String { "puzzlepiece.extension" }
  var commands: [PluginCommand] { [] }

  init(
    record: PluginRecord, host: PluginHost, environment: PluginEnvironment = .none,
    reconnect: (@MainActor () async throws -> Void)? = nil, compact: Bool, onClose: @escaping (UUID) -> Void
  ) {
    self.record = record
    self.host = host
    self.environment = environment
    self.reconnect = reconnect
    self.compact = compact
    self.onClose = onClose
    starting = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let opened = try await host.activate(
          id: record.id, runtime: runtime, environment: environment, reconnect: reconnect)
        guard !closed, !Task.isCancelled else { host.unload(session: opened); return }
        session = opened
      } catch {
        guard !closed, !Task.isCancelled else { return }
        failure = error.localizedDescription
      }
    }
  }
  func content() -> AnyView { AnyView(Surface(workspace: self)) }

  // Read observable state inside a SwiftUI body, rather than capturing the
  // initial loading branch in the AnyView handed to an AppKit hosting view.
  private struct Surface: View {
    let workspace: WebPluginWorkspace
    var body: some View {
      Group {
        if workspace.closed { Color.clear }
        else if let failure = workspace.failure {
          Text(failure)
            .font(UIStyle.input)
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(UIStyle.Space.section)
        } else if let session = workspace.session {
          PluginSurface(runtime: workspace.runtime, session: session)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }.frame(width: workspace.compact ? 400 : nil, height: workspace.compact ? 450 : nil)
    }
  }
  func inspector() -> AnyView { AnyView(EmptyView()) }
  func close() {
    guard !closed else { return }
    closed = true
    starting?.cancel()
    if let session { host.unload(session: session) }
    session = nil
    onClose(id)
  }
}
