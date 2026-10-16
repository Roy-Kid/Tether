import SwiftUI
import TetherUI

/// The rest of Identities: the library's iCloud copy, key bindings, and on a
/// Mac the SSH configuration that feeds it.
struct SyncSettings: View {
  @Bindable var store: HostStore

  var body: some View {
    Section("iCloud") {
      LabeledContent("Status") {
        Text(store.syncStatus)
        SettingsAction("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await store.syncEverything() } }
          .disabled(store.syncing)
      }
      if let last = store.lastSynced {
        LabeledContent("Last Synced") { Text(last, format: .relative(presentation: .named)) }
      }
      LabeledContent("Hosts", value: String(store.hosts.count))
      if let bindings = store.keyBindings {
        LabeledContent("Key Bindings", value: bindings.pending.isEmpty
          ? "Included in sync" : "\(bindings.pending.count) pending changes")
      }
      if let failure = store.syncFailure {
        Text(failure).foregroundStyle(Theme.danger).textSelection(.enabled)
      }
    }

    #if os(macOS)
      Section {
        LabeledContent("Configuration") {
          Text(Self.shortened(store.location.path))
            .lineLimit(1).truncationMode(.middle)
          SettingsAction("Import SSH Configuration", systemImage: "square.and.arrow.down") { store.importConfiguration() }
            .disabled(store.unreadable)
        }
        ForEach(store.hosts.filter { $0.routeProblem != nil }) { host in
          LabeledContent(host.label, value: host.routeProblem ?? "")
        }
      } header: {
        Text("SSH Configuration")
      }
      .help("Import copies this file over the hosts it names. Opening asks first. Hosts the file does not name stay. The file itself is left as it is.")
    #endif

    let missing = store.hosts.filter {
      $0.isManaged && !$0.isLocal && $0.credentialSecretID == nil && $0.keyPath == nil && !$0.usesDefaultKeys
    }
    if !missing.isEmpty {
      Section {
        ForEach(missing) { host in LabeledContent(host.label, value: host.address) }
        SettingsAction("Create SSH Keys", systemImage: "key") {
          for host in missing { store.generateKey(for: host) }
        }
      } header: {
        Text("SSH Keys")
      }
      .help("A key from your other devices arrives with the host. Create one here when none does. The server has to authorize that public key before it can connect.")
    }
  }

  /// `~/.ssh/config` reads better than the whole path.
  private static func shortened(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}
