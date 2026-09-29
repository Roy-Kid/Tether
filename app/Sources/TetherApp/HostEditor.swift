import SwiftUI
import UniformTypeIdentifiers
import TetherUI

/// Adding or changing a saved host.
///
/// Laid out like a connection editor, not a settings page: address first,
/// then who you are, then the secret. Password is typed here and kept; the
/// connect sheet is only for hosts that still have none.
struct HostEditor: View {
  private enum Authentication: Hashable {
    case password, key
  }

  @State private var host: Host
  @State private var password: String
  let onSave: (Host, String?) -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var picking = false
  @State private var importProblem: String?
  @State private var authentication: Authentication
  /// A key picked in this sheet, held until Save. Written to the keychain
  /// only then, so a sheet cancelled after picking leaves nothing behind.
  @State private var pickedKey: String?

  private var isNew: Bool { host.hostname.isEmpty && host.label.isEmpty }

  private var canSave: Bool {
    !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
      && !host.username.trimmingCharacters(in: .whitespaces).isEmpty
      && (authentication == .password || host.offersConfiguredKey || pickedKey != nil)
  }

  init(host: Host, password: String = "", onSave: @escaping (Host, String?) -> Bool) {
    self.onSave = onSave
    _host = State(initialValue: host)
    _password = State(initialValue: password)
    _authentication = State(initialValue: host.offersConfiguredKey ? .key : .password)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Address", text: $host.hostname, prompt: Text("hostname or IP"))
            .hostFieldKeyboard()
            #if os(iOS)
              .keyboardType(.URL)
              .textContentType(.URL)
            #endif
          TextField("Label", text: $host.label)
            .hostFieldKeyboard()
          TextField("Port", text: portText)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
        }

        if host.profile != nil {
          Section("Identity") {
            TextField("Account Identity", text: Binding(
              get: { host.profile?.authentication.identity.name ?? "" },
              set: { host.profile?.authentication.identity.name = $0 }))
            Picker("Confirmation", selection: Binding(
              get: { host.profile?.authentication.confirmation ?? .confirmAuthentication },
              set: { host.profile?.authentication.confirmation = $0 })) {
                Text("Automatic").tag(ConfirmationPolicy.automatic)
                Text("Before Authentication").tag(ConfirmationPolicy.confirmAuthentication)
                Text("Every Connection").tag(ConfirmationPolicy.confirmConnection)
              }
            if host.profile?.authentication.otp != nil {
              TextField("OTP Challenge", text: Binding(
                get: { host.profile?.authentication.otpPrompt ?? "" },
                set: { host.profile?.authentication.otpPrompt = $0 }))
            }
          }
        }
        Section {
          TextField("Username", text: $host.username)
            .hostFieldKeyboard()
            #if os(iOS)
              .textContentType(.username)
            #endif
          authenticationChoice

          if let importProblem { Text(importProblem).foregroundStyle(.red) }
          if authentication == .password {
            // A row of its own. Nesting `SecureField` in an `HStack` inside a
            // `Form` is how iOS ends up with a password row that will not
            // take focus or open the keyboard.
            SecureField("Password", text: $password)
              #if os(iOS)
                .textContentType(.password)
              #endif
          } else {
            Button {
              picking = true
            } label: {
              LabeledContent("Key") {
                Text(pickedKey != nil || host.credentialSecretID != nil ? "Stored on this device" : host.keyPath.map(shorten) ?? "Choose…")
                  .foregroundStyle(.secondary)
                  .adaptiveRowText()
                  .truncationMode(.head)
              }
            }
            .foregroundStyle(.primary)
            if host.keyPath != nil || host.credentialSecretID != nil || pickedKey != nil {
              Button("Clear Key", role: .destructive) {
                host.keyPath = nil
                host.credentialSecretID = nil
                pickedKey = nil
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
      #endif
      .onChange(of: authentication) { _, value in
        if value == .password {
          host.keyPath = nil
          host.credentialSecretID = nil
          pickedKey = nil
        } else {
          password = ""
        }
      }
      .navigationTitle(isNew ? "New Host" : "Edit Host")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { commit() }
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
      }
      .fileImporter(
        isPresented: $picking,
        allowedContentTypes: [.data],
        allowsMultipleSelection: false,
        onCompletion: adoptKey)
      #if os(macOS)
        .fileDialogDefaultDirectory(
          URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appending(path: ".ssh"))
      #endif
    }
    #if os(macOS)
      .frame(minWidth: Chrome.editorWidth, minHeight: Chrome.editorHeight)
    #endif
  }

  private var authenticationChoice: some View {
    HStack(spacing: UIStyle.Space.section) {
      method(.password, "Password", "lock")
      method(.key, "Key", "key")
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Authentication")
  }

  private func method(_ kind: Authentication, _ title: String, _ symbol: String) -> some View {
    let selected = authentication == kind
    return Button {
      authentication = kind
    } label: {
      VStack(spacing: UIStyle.Space.small) {
        Label(title, systemImage: symbol)
          .font(selected ? UIStyle.title : UIStyle.detail)
          .foregroundStyle(selected ? Theme.text : Theme.subtle)
        Rectangle()
          .fill(selected ? Theme.text : Theme.stroke.opacity(0.35))
          .frame(height: UIStyle.Mark.hairline)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  /// A key picked here is written on Save and syncs with the host. A password
  /// stays on this device.
  private func commit() {
    var saved = host
    if authentication == .password {
      saved.keyPath = nil
      saved.credentialSecretID = nil
    }
    saved.label =
      host.label.trimmingCharacters(in: .whitespaces).isEmpty
      ? host.hostname : host.label
    var written: UUID?
    if authentication == .key, let pickedKey {
      let id = UUID()
      do {
        try DeviceCredentialStore().write(pickedKey, id: id, label: saved.label)
      } catch {
        importProblem = error.localizedDescription
        return
      }
      saved.credentialSecretID = id
      saved.keyPath = nil
      written = id
    }
    if onSave(saved, authentication == .password ? password : "") {
      dismiss()
    } else if let written {
      // Not saved, so nothing points at it.
      try? DeviceCredentialStore().forget(written)
    }
  }

  /// `~/.ssh/id_ed25519` reads better than the whole path, and the whole
  /// path is what the tooltip and the stored value keep.
  private func shorten(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  /// Takes the file a person chose.
  ///
  /// `NSOpenPanel` is a Mac window and there is no phone equivalent, so the
  /// picker is SwiftUI's `fileImporter` on both — one code path, and the one
  /// that already knows how to reach a document provider on a phone.
  ///
  /// The key itself is kept, in this device's keychain, not the path: a file
  /// picked here is reachable only for the moment the picker grants — always
  /// so on a phone — and a path that reads fine now would fail at connect
  /// time. Held until Save; `commit` writes it.
  func adoptKey(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result, let url = urls.first else { return }

    // A sandboxed pick hands back a URL that is only reachable inside this
    // call unless the access is opened explicitly. Storing the path without
    // it would give a path that reads fine here and fails at connect time.
    let reachable = url.startAccessingSecurityScopedResource()
    defer { if reachable { url.stopAccessingSecurityScopedResource() } }

    do {
      pickedKey = try String(contentsOf: url, encoding: .utf8)
      importProblem = nil
    } catch {
      importProblem = error.localizedDescription
    }
  }

  /// The port as text, so an empty field is possible while typing.
  /// Falling back to 22 rather than refusing a blank: 22 is what an empty
  /// port means, and an error on a field someone is still filling in is
  /// noise.
  private var portText: Binding<String> {
    Binding(
      get: { String(host.port) },
      set: { host.port = UInt16($0.filter(\.isNumber)) ?? 22 })
  }
}

private extension View {
  /// Host names, aliases and users are typed as written. The phone keyboard
  /// otherwise capitalises the first letter of an address and offers to
  /// correct `hpc` into a word.
  func hostFieldKeyboard() -> some View {
    #if os(iOS)
      self.textInputAutocapitalization(.never).autocorrectionDisabled()
    #else
      self
    #endif
  }
}
