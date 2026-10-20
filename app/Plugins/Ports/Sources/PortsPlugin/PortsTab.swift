import SwiftUI
import Tether
import TetherPluginKit
import TetherUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor
final class PortsTab: TabAttachment {
  private let hostID: UUID
  private let table: PortTable

  init(hostID: UUID, lease: any PortLease, polling: Bool = true) {
    self.hostID = hostID
    table = PortTables.retain(host: hostID, lease: lease, polling: polling)
  }

  var isShowing: Bool { false }
  var subtitle: String { "" }
  var isDisconnected: Bool { false }
  var closeNote: String? { nil }
  var commands: [PluginCommand] { [] }

  func content() -> AnyView { AnyView(EmptyView()) }
  func inspector() -> AnyView { AnyView(PortsList(table: table)) }
  func accessoryContent() -> AnyView { inspector() }

  func connectionChanged(_ connection: RemoteConnection) {
    let lease = LiveLease(connection)
    Task { await table.adopt(lease) }
  }

  func close() { PortTables.release(host: hostID) }
}

struct PortsList: View {
  var table: PortTable
  @Environment(\.workspaceBackgroundOpacity) private var backgroundOpacity

  var body: some View {
    VStack(spacing: 0) {
      bar
      Divider()
      if table.rows.isEmpty {
        QuietMark("Ports", systemImage: "network")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: UIStyle.Space.inline) {
            ForEach(table.rows) { row in
              PortsRow(table: table, row: row)
            }
          }
          .padding(UIStyle.Space.group)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // What polling knows of being looked at: the inspector, the popover
    // and a phone's sheet all draw this list.
    .onAppear { table.shown() }
    .onDisappear { table.hidden() }
  }

  /// Stays up when the list is empty, so Refresh is always there.
  private var bar: some View {
    HStack(spacing: UIStyle.Space.tight) {
      Spacer(minLength: 0)
      if table.scanFailed {
        Image(systemName: "exclamationmark.triangle")
          .font(UIStyle.symbol)
          .foregroundStyle(Theme.warning)
          .help(table.problem ?? "Refresh failed")
      }
      ZStack {
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await table.refresh() }
        }
        .labelStyle(.iconOnly)
        .font(UIStyle.symbol)
        .frame(width: UIStyle.controlHeight, height: UIStyle.controlHeight)
        .buttonStyle(ChromeButtonStyle())
        .disabled(table.scanning)
        .opacity(table.scanning ? 0 : 1)
        .help("Refresh")
        .accessibilityLabel("Refresh")
        if table.scanning {
          ProgressView().controlSize(.mini).accessibilityLabel("Refresh")
        }
      }
      .frame(width: UIStyle.controlHeight, height: UIStyle.controlHeight)
    }
    .padding(.horizontal, UIStyle.Space.group)
    .frame(height: UIStyle.controlHeight + UIStyle.Space.group)
    .frame(maxWidth: .infinity)
    .background(backgroundOpacity < 1 ? Color.clear : Theme.sidebar)
  }
}

private struct PortsRow: View {
  var table: PortTable
  var row: PortRow

  var body: some View {
    HStack(spacing: UIStyle.Space.inline) {
      Button {
        Task {
          await table.forward(row.port)
          if let current = table.rows.first(where: { $0.port == row.port }), current.forwarded {
            open(current)
          }
        }
      } label: {
        Text(row.label)
          .font(UIStyle.detail.monospaced())
          .lineLimit(1)
      }
      .buttonStyle(.plain)
      .help("Open")
      Text(row.name)
        .font(UIStyle.detail)
        .foregroundStyle(Theme.subtle)
        .lineLimit(1)
      Spacer(minLength: UIStyle.Space.small)
      if let error = row.error {
        Image(systemName: "exclamationmark.triangle")
          .font(UIStyle.symbol)
          .foregroundStyle(Theme.warning)
          .help(error)
      }
      if row.forwarded {
        Button {
          open(row)
        } label: {
          Label("Open", systemImage: "safari")
        }
        .buttonStyle(.iconOnly)
        .help("Open")
      } else if row.error == nil {
        Button {
          Task { await table.forward(row.port) }
        } label: {
          Label("Forward", systemImage: "arrow.right")
        }
        .buttonStyle(.iconOnly)
        .help("Forward")
      }
      Button {
        table.close(row.port)
      } label: {
        Label("Close", systemImage: "xmark")
      }
      .buttonStyle(.iconOnly)
      .help("Close")
    }
    .frame(minHeight: UIStyle.rowHeight)
  }

  private func open(_ row: PortRow) {
    guard let local = row.localPort, let url = URL(string: "http://127.0.0.1:\(local)") else { return }
    #if os(macOS)
      NSWorkspace.shared.open(url)
    #else
      UIApplication.shared.open(url)
    #endif
  }
}
