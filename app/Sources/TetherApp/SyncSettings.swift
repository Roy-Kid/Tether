import SwiftUI

/// Hosts and key bindings share the same iCloud account and sync engine.
struct SyncSettings: View {
  @Bindable var store: HostStore

  var body: some View {
    Section("iCloud") {
      LabeledContent("Status", value: store.syncStatus)
      if let last = store.lastSynced {
        LabeledContent("Last Synced") { Text(last, format: .relative(presentation: .named)) }
      }
      LabeledContent("Hosts", value: String(store.hosts.count))
      if let bindings = store.keyBindings {
        LabeledContent("Key Bindings", value: bindings.pending.isEmpty
          ? "Included in sync" : "\(bindings.pending.count) pending changes")
      }
      if let failure = store.syncFailure {
        Text(failure).foregroundStyle(.red).textSelection(.enabled)
      }
      Button("Sync Now") { Task { await store.syncEverything() } }
        .disabled(store.syncing)
    }

    #if os(macOS)
      Section {
        LabeledContent("Configuration", value: Self.shortened(store.location.path))
        ForEach(store.hosts.filter { $0.routeProblem != nil }) { host in
          LabeledContent(host.label, value: host.routeProblem ?? "")
        }
      } header: {
        Text("SSH Configuration")
      } footer: {
        Text("Hosts this file names join the library, and an edited stanza updates its host. The file is only read: a change or deletion in Tether stays in Tether, and a stanza taken out of the file leaves its host in place. A private key this Mac uses syncs to the other devices on this Apple ID. Passwords stay on this device.")
      }
    #endif

    let missing = store.hosts.filter {
      $0.isManaged && !$0.isLocal && $0.credentialSecretID == nil && $0.keyPath == nil && !$0.usesDefaultKeys
    }
    if !missing.isEmpty {
      Section {
        ForEach(missing) { host in LabeledContent(host.label, value: host.address) }
        Button("Create SSH Keys") {
          for host in missing { store.generateKey(for: host) }
        }
      } header: {
        Text("SSH Keys")
      } footer: {
        Text("A key from your other devices arrives with the host. Create one here when none does. The server has to authorize that public key before it can connect.")
      }
    }
  }

  /// `~/.ssh/config` reads better than the whole path.
  private static func shortened(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}
