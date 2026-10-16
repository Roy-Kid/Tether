import AuthenticationServices
import SwiftUI
import TetherUI

/// An export a password manager sent here, waiting for a person to say
/// which of it their hosts keep.
///
/// The export is started in the password manager — the system offers this
/// app as a destination because it carries a credential provider extension
/// that says it takes Credential Exchange — and arrives as a user activity
/// with a one-time token. What the token reads stays in memory until the
/// page is answered — in Settings ▸ Identities, where hosts are managed —
/// and only what the person chose is ever stored.
@MainActor
@Observable
final class CredentialImport {
  static let shared = CredentialImport()

  struct Pending: Identifiable {
    let id = UUID()
    let exporter: String
    let items: [CredentialExchange.Item]
  }

  struct Notice: Hashable {
    let title: String
    var message: String?
  }

  var pending: Pending?
  var notice: Notice?

  /// Takes the activity when it is an export, and reads it.
  @discardableResult
  func receive(_ activity: NSUserActivity) -> Bool {
    guard activity.activityType == ASCredentialExchangeActivity,
      let token = activity.userInfo?[ASCredentialImportToken] as? UUID else { return false }
    Task { await read(token) }
    return true
  }

  private func read(_ token: UUID) async {
    do {
      let data = try await ASCredentialImportManager().importCredentials(token: token)
      let items = CredentialExchange.items(in: data)
      if items.isEmpty {
        notice = Notice(title: "Nothing to Import")
      } else {
        pending = Pending(exporter: data.exporterDisplayName, items: items)
        SettingsRoute.shared.show(.importing)
      }
    } catch let error as ASAuthorizationError where error.code == .canceled {
      // Their own no ends quietly.
    } catch is CancellationError {
    } catch {
      notice = Notice(title: "Could Not Import", message: error.localizedDescription)
    }
  }
}

/// Which host keeps what. A row per item that names a host, with what that
/// host already has left unchosen; the items that name none are folded away,
/// to be given a host or left behind.
///
/// Worded, unlike the window's chrome: each switch decides what a host logs
/// in with, and a symbol alone did not say which secret it was.
struct CredentialImportPage: View {
  @Bindable var store: HostStore
  let pending: CredentialImport.Pending
  let done: () -> Void
  @State private var choices: [CredentialExchange.Choice] = []
  @State private var matched: Set<Data> = []
  @State private var showsUnmatched = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        if !matched.isEmpty {
          Section {
            ForEach(indices(matched: true), id: \.self) { row($choices[$0], picksHost: false) }
          }
        }
        let unmatched = indices(matched: false)
        if !unmatched.isEmpty {
          Section {
            DisclosureGroup("Unmatched (\(unmatched.count))", isExpanded: $showsUnmatched) {
              ForEach(unmatched, id: \.self) { row($choices[$0], picksHost: true) }
            }
          }
        }
      }
      .formStyle(.grouped)
      #if os(macOS)
        .scrollContentBackground(.hidden)
      #endif
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { done() }
          .keyboardShortcut(.cancelAction)
        Button("Import") {
          store.adopt(choices)
          done()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!choices.contains(where: \.takesAnything))
      }
      .padding([.horizontal, .bottom], UIStyle.Space.section)
    }
    .onAppear {
      choices = CredentialExchange.choices(for: pending.items, hosts: store.hosts)
      matched = Set(choices.filter { $0.host != nil }.map(\.id))
      showsUnmatched = matched.isEmpty
    }
  }

  private func indices(matched wanted: Bool) -> [Int] {
    choices.indices.filter { matched.contains(choices[$0].id) == wanted }
  }

  private func row(_ choice: Binding<CredentialExchange.Choice>, picksHost: Bool) -> some View {
    let item = choice.wrappedValue.item
    let host = store.hosts.first { $0.id == choice.wrappedValue.host }
    return VStack(alignment: .leading, spacing: UIStyle.Space.small) {
      if picksHost {
        // A host picked here is chosen for afresh: what it already has
        // stays unless turned on.
        Picker(item.title, selection: Binding(
          get: { choice.wrappedValue.host },
          set: { id in choice.wrappedValue = CredentialExchange.choice(item, for: store.hosts.first { $0.id == id }) }
        )) {
          Text("None").tag(nil as UUID?)
          ForEach(store.hosts) { Text($0.label).tag(Optional($0.id)) }
        }
      } else {
        Text(host?.label ?? item.title)
      }
      if let detail = detail(item, host: host, picksHost: picksHost) {
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      if host != nil {
        secrets(choice, item: item, host: host)
      }
    }
    .padding(.vertical, UIStyle.Space.small)
  }

  /// The item as the password manager named it, where that is not already
  /// the line above, and the account.
  private func detail(_ item: CredentialExchange.Item, host: Host?, picksHost: Bool) -> String? {
    let title = picksHost || item.title.caseInsensitiveCompare(host?.label ?? "") == .orderedSame ? nil : item.title
    let parts = [title, item.userName].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func secrets(_ choice: Binding<CredentialExchange.Choice>, item: CredentialExchange.Item, host: Host?) -> some View {
    HStack(spacing: UIStyle.Space.inset) {
      if item.secrets.privateKey != nil {
        secret("SSH Key", isOn: choice.privateKey, replaces: host.map(CredentialExchange.hasKey) == true)
      }
      if item.secrets.password != nil {
        secret("Password", isOn: choice.password, replaces: host?.remembersPassword == true)
      }
      if item.secrets.code != nil {
        secret("Verification Code", isOn: choice.code, replaces: host?.otpSecretID != nil)
      }
    }
  }

  private func secret(_ name: String, isOn: Binding<Bool>, replaces: Bool) -> some View {
    Toggle(replaces ? "Replace \(name)" : name, isOn: isOn)
      #if os(macOS)
        .toggleStyle(.checkbox)
      #else
        .toggleStyle(.button)
      #endif
      .fixedSize()
  }
}
