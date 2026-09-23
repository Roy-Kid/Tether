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
  let onSave: (Host, String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var picking = false
  @State private var authentication: Authentication

  private var isNew: Bool { host.hostname.isEmpty && host.label.isEmpty }

  private var canSave: Bool {
    !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
      && !host.username.trimmingCharacters(in: .whitespaces).isEmpty
      && (authentication == .password || host.offersConfiguredKey)
  }

  init(host: Host, password: String = "", onSave: @escaping (Host, String?) -> Void) {
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

        Section {
          TextField("Username", text: $host.username)
            .hostFieldKeyboard()
            #if os(iOS)
              .textContentType(.username)
            #endif
          Picker("Authentication", selection: $authentication) {
            Text("Password").tag(Authentication.password)
            Text("Key").tag(Authentication.key)
          }
          .pickerStyle(.segmented)

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
                Text(host.keyPath.map(shorten) ?? "Choose…")
                  .foregroundStyle(.secondary)
                  .adaptiveRowText()
                  .truncationMode(.head)
              }
            }
            .foregroundStyle(.primary)
            if host.keyPath != nil {
              Button("Clear Key", role: .destructive) { host.keyPath = nil }
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
      .frame(minWidth: 440, minHeight: 480)
    #endif
  }

  private func commit() {
    var saved = host
    if authentication == .password {
      saved.keyPath = nil
    }
    saved.label =
      host.label.trimmingCharacters(in: .whitespaces).isEmpty
      ? host.hostname : host.label
    onSave(saved, authentication == .password ? password : "")
    dismiss()
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
  /// The path is stored, never the key. Reading happens at connect time, so a
  /// key that moved or had its permissions tightened is noticed when there is
  /// someone to tell (spec §18).
  func adoptKey(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result, let url = urls.first else { return }

    // A sandboxed pick hands back a URL that is only reachable inside this
    // call unless the access is opened explicitly. Storing the path without
    // it would give a path that reads fine here and fails at connect time.
    let reachable = url.startAccessingSecurityScopedResource()
    defer { if reachable { url.stopAccessingSecurityScopedResource() } }

    host.keyPath = persistIdentity(url) ?? url.path
  }

  /// Copies a picked key into `~/.ssh` so connect-time reads do not depend
  /// on a security-scoped URL that dies at the end of this call. On a phone
  /// that is the difference between offering publickey and failing with
  /// "the server still wants publickey, keyboard-interactive".
  private func persistIdentity(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appending(path: ".ssh", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let name = url.lastPathComponent.isEmpty ? "id_key" : url.lastPathComponent
    let destination = directory.appending(path: name)
    do {
      try data.write(to: destination, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch {
      return nil
    }
    return contractingHome(destination.path)
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

/// Asks for the credential, once, at the moment of connecting.
///
/// Hosts that already have a password in the keychain, or a key, skip this.
struct ConnectSheet: View {
  let host: Host
  let remembered: String?
  let onConnect: (_ password: String, _ remember: Bool) -> Void

  @State private var password: String
  @State private var remember: Bool
  @Environment(\.dismiss) private var dismiss

  init(host: Host, remembered: String? = nil, onConnect: @escaping (String, Bool) -> Void) {
    self.host = host
    self.remembered = remembered
    self.onConnect = onConnect
    _password = State(initialValue: remembered ?? "")
    _remember = State(initialValue: remembered != nil)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("Password", text: $password)
            #if os(iOS)
              .textContentType(.password)
            #endif
          Toggle("Remember password", isOn: $remember)
            .disabled(password.isEmpty)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(host.label.isEmpty ? host.hostname : host.label)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Connect") {
            onConnect(password, remember && !password.isEmpty)
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 380, minHeight: 240)
    #endif
  }
}
