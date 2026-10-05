import SwiftUI
import TetherUI

/// Security details live in settings and sheets, not in the terminal chrome.
struct IdentitySettings: View {
  @Bindable var store: HostStore
  var connections: TabSet? = nil
  @State private var selected: Host?

  var body: some View {
    Section {
      ForEach(store.hosts) { host in
        let problem = host.connectionProblem ?? host.routeProblem
        Button { selected = host } label: {
          HStack(spacing: UIStyle.Space.group) {
            Text(host.label)
              .foregroundStyle(Theme.text)
              .adaptiveRowText()
            Spacer(minLength: UIStyle.Space.small)
            Image(systemName: problem == nil ? "checkmark" : "exclamationmark.triangle")
              .font(UIStyle.symbol)
              .foregroundStyle(problem == nil ? Theme.success : Theme.warning)
          }
        }
        .buttonStyle(.borderless)
        .help(problem ?? "Ready")
        .accessibilityLabel(host.label)
        .accessibilityValue(problem ?? "Ready")
      }
      if let problem = store.problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
    }
    .sheet(item: $selected) { host in
      NavigationStack { HostIdentitySettings(store: store, id: host.id, connections: connections) }
        .frame(minWidth: UIStyle.sheetWidth, minHeight: UIStyle.sheetHeight)
    }
  }
}

struct HostIdentitySettings: View {
  @Bindable var store: HostStore
  let id: UUID
  var connections: TabSet? = nil
  @State private var seed = ""
  @State private var confirmingDelete = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      if let host = store.hosts.first(where: { $0.id == id }) {
        Section("Connection") {
          LabeledContent("Host", value: host.hostname)
          LabeledContent("User", value: host.username)
          LabeledContent("Port", value: String(host.port))
          if let issue = host.connectionProblem { Text(issue).foregroundStyle(.orange) }
        }
        if let profile = host.profile {
          Section("Authentication") {
            LabeledContent("Identity", value: profile.authentication.identity.name)
            // Whether this device has a key, including one that arrived with the host.
            LabeledContent("Method", value: host.offersConfiguredKey || host.usesDefaultKeys ? "Key" : "Password")
            LabeledContent("Confirmation", value: profile.authentication.confirmation.rawValue)
            if profile.authentication.otp != nil {
              LabeledContent("MFA", value: "TOTP")
              LabeledContent("Challenge", value: profile.authentication.otpPrompt)
              Picker("MFA Device", selection: Binding(
                get: { profile.authentication.remoteApprovalDevice },
                set: { device in
                  var updated = host
                  updated.profile?.authentication.remoteApprovalDevice = device
                  _ = store.save(updated)
                })) {
                  Text("This Device").tag(nil as UUID?)
                  ForEach(store.continuity?.peers.filter { !$0.revoked } ?? []) { peer in
                    Text(peer.card.name).tag(Optional(peer.id))
                  }
                }
            }
            if let record = store.snapshot.records[id], !record.conflicts.isEmpty {
              ForEach(record.conflicts.keys.sorted(), id: \.self) { field in
                VStack(alignment: .leading) {
                  Text(field).bold()
                  Text("This device: " + (String(data: record.conflicts[field]?.local ?? Data(), encoding: .utf8) ?? "Deleted"))
                  Text("iCloud: " + (String(data: record.conflicts[field]?.remote ?? Data(), encoding: .utf8) ?? "Deleted"))
                }.textSelection(.enabled)
              }
              Button("Keep This Device’s Changes") { store.resolve(id, useRemote: false) }
              Button("Use iCloud Changes") { store.resolve(id, useRemote: true) }
            }
          }
          Section("This Device") {
            if let binding = store.snapshot.bindings[profile.authentication.primary.id] {
              if let publicKey = binding.publicKey {
                Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                ShareLink("Export Public Key", item: publicKey)
                  .help("The server has to authorize this public key before it can connect. The same key syncs to your other devices.")
              } else if let path = binding.keyPath {
                LabeledContent("SSH Key", value: path)
              } else if binding.defaultKeys == true {
                LabeledContent("SSH Key", value: "Default SSH keys")
              } else {
                LabeledContent("SSH Key", value: "Synced")
              }
            } else {
              Button("Create SSH Key") { store.generateKey(for: host) }
                .help("The server has to authorize this public key before it can connect. The same key syncs to your other devices.")
            }
          }
          AuthorizationSettings(store: store, host: host, connections: connections)
          Section("MFA on This Device") {
            SecureField("TOTP secret or otpauth URI", text: $seed)
            Button("Save MFA Credential") {
              store.setOTP(seed, for: host)
              seed = ""
            }.disabled(seed.isEmpty)
          }
        }
        if let problem = store.problem { Text(problem).foregroundStyle(.red) }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Identity and Authentication")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Delete", role: .destructive) { confirmingDelete = true }
          .disabled(store.hosts.first { $0.id == id }?.isManaged != true)
      }
      ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
    }
    .dialog(for: confirmingDelete ? id : nil) { id in
      let name = store.hosts.first { $0.id == id }?.label ?? "Host"
      return Dialog.confirm(
        "Delete \(name)?", verb: "Delete", role: .destructive,
        cancel: { confirmingDelete = false }
      ) {
        if let host = store.hosts.first(where: { $0.id == id }) { store.delete(host) }
        confirmingDelete = false
        dismiss()
      }
    }
  }
}

struct DeviceSettings: View {
  @Bindable var store: HostStore
  let known: KnownHosts
  @State private var name = "My Apple device"
  @State private var code = ""
  @State private var candidate: DeviceCard?
  @State private var parseProblem: String?

  var body: some View {
    Section("Trusted Devices") {
      if let center = store.continuity {
        if let local = center.local {
          LabeledContent("This Device", value: local.name)
          ShareLink("Share Pairing Code", item: local.pairingCode)
          Text(local.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
          TextField("Other device’s pairing code", text: $code)
          Button("Review Device") {
            do { candidate = try DeviceCard.parse(code); parseProblem = nil }
            catch { parseProblem = error.localizedDescription }
          }.disabled(code.isEmpty)
          if let candidate {
            LabeledContent("Device", value: candidate.name)
            Text(candidate.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
            Button("Trust This Device") { center.pair(candidate); self.candidate = nil; code = "" }
              .help("Compare this fingerprint with the other device before trusting it. Exchange codes on both devices.")
          }
          if store.snapshot.trust.localRevoked {
            Text("This device’s approval authority has been revoked.").foregroundStyle(.red)
          }
          ForEach(center.discovered.filter { card in !center.peers.contains { $0.id == card.id } }) { card in
            LabeledContent(card.name, value: "Discovered — not trusted")
          }
          ForEach(center.peers) { peer in
            HStack {
              Text(peer.card.name)
              Spacer()
              if peer.revoked { Text("Revoked").foregroundStyle(.secondary) }
              else {
                Button("Revoke", role: .destructive) { center.revoke(peer.id) }
                  .help("Revoking a device stops its approvals. A key already on a server stays until that authorization is removed.")
              }
            }
          }
          Button("Check Approval Requests") { Task { await center.refresh() } }
          ForEach(center.requests) { request in
            VStack(alignment: .leading, spacing: UIStyle.Space.group) {
              Text(center.peers.first(where: { $0.id == request.sender })?.card.name ?? "Unknown device").bold()
              Text("\(request.username)@\(request.hostname):\(request.port)")
              Text(request.hostFingerprint).font(.caption.monospaced()).textSelection(.enabled)
              HStack {
                Button("Approve") { Task { await center.respond(request, approve: true, known: known) } }
                Button("Reject", role: .destructive) { Task { await center.respond(request, approve: false, known: known) } }
              }
            }
          }
        } else {
          TextField("Device Name", text: $name)
          Button("Enable Device Approval") { center.enable(name: name) }.disabled(name.isEmpty)
        }
        if let problem = center.problem { Text(problem).foregroundStyle(.red) }
      } else {
        Button("Set Up Device Approval") { Task { await store.startSync() } }
      }
      if let parseProblem { Text(parseProblem).foregroundStyle(.red) }
    }
    .task {
      while !Task.isCancelled {
        await store.continuity?.refresh()
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
      }
    }
  }
}

struct AuthorizationSettings: View {
  @Bindable var store: HostStore
  let host: Host
  let connections: TabSet?
  @State private var publicKey = ""
  @State private var deviceLabel = ""
  @State private var applying = false

  var body: some View {
    Section("Remote Authorization") {
      TextField("Device Name", text: $deviceLabel)
      TextField("SSH Public Key", text: $publicKey)
      Button("Prepare Administrator Request") {
        do {
          let key = try AuthorizedKeysProvider.keyMaterial(publicKey)
          let record = RemoteAuthorization(hostID: host.id, publicKey: key, deviceLabel: deviceLabel,
            provider: "manual", state: .awaitingAdministrator)
          try store.update { $0.authorizations[record.id] = record }
        } catch { store.recordProblem(error) }
      }.disabled(publicKey.isEmpty || deviceLabel.isEmpty)
      Button("Install Public Key on This Host") {
        Task { await install() }
      }
      .disabled(applying || publicKey.isEmpty || deviceLabel.isEmpty || connections == nil)
      .help("Installation requires an existing connection and permission to manage authorized_keys. Administrator-managed hosts need an administrator’s approval.")
      ForEach(store.snapshot.authorizations.values.filter { $0.hostID == host.id }.sorted { $0.deviceLabel < $1.deviceLabel }) { record in
        VStack(alignment: .leading) {
          LabeledContent(record.deviceLabel, value: record.state.rawValue)
          ShareLink("Export Public Key", item: record.publicKey)
          if let detail = record.detail { Text(detail).font(.caption) }
          if record.provider == "authorized_keys", record.state != .revoked {
            Button("Remove This Authorization", role: .destructive) { Task { await revoke(record) } }.disabled(applying)
          }
        }
      }
    }
  }
  private func install() async {
    applying = true
    defer { applying = false }
    do {
      guard let connection = try await connections?.lease(for: host) else {
        throw IdentityError.storage("Connect to this host before installing a key.")
      }
      let key = try AuthorizedKeysProvider.keyMaterial(publicKey)
      guard store.scope == host.accountScope else { throw CancellationError() }
      var record = store.snapshot.authorizations.values.first {
        $0.hostID == host.id && $0.publicKey == key && $0.provider == "authorized_keys" && $0.state != .revoked
      } ?? RemoteAuthorization(hostID: host.id, publicKey: key, deviceLabel: deviceLabel,
        provider: "authorized_keys", state: .failed)
      // Persist the ownership marker before touching the server so retry/revoke
      // can find an entry even when the network drops after installation.
      try store.update { $0.authorizations[record.id] = record }
      do {
        try await AuthorizedKeysProvider().enroll(record, on: connection)
        record.state = .installed
        record.detail = "Installed. Verify by logging in from the new device."
      } catch { record.detail = error.localizedDescription }
      guard store.scope == host.accountScope else { throw CancellationError() }
      let completed = record
      try store.update { $0.authorizations[completed.id] = completed }
    } catch { store.recordProblem(error) }
  }
  private func revoke(_ record: RemoteAuthorization) async {
    applying = true
    defer { applying = false }
    do {
      guard store.scope == host.accountScope else { throw CancellationError() }
      try store.update { $0.authorizations[record.id]?.state = .revocationPending }
      guard let connection = try await connections?.lease(for: host) else {
        throw IdentityError.storage("Connect to this host to finish revocation.")
      }
      try await AuthorizedKeysProvider().revoke(record, on: connection)
      guard store.scope == host.accountScope else { throw CancellationError() }
      try store.update { $0.authorizations[record.id]?.state = .revoked }
    } catch { store.recordProblem(error) }
  }
}
