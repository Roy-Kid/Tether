import SwiftUI
import UniformTypeIdentifiers

/// Adding or changing a saved host.
struct HostEditor: View {
  @State var host: Host
  let onSave: (Host) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var picking = false

  private var isNew: Bool { host.hostname.isEmpty && host.label.isEmpty }

  private var canSave: Bool {
    !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
      && !host.username.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(isNew ? "New host" : "Edit host")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Theme.text)

      Field(
        label: "Name",
        text: $host.label,
        placeholder: host.hostname.isEmpty ? "Lab workstation" : host.hostname)

      HStack(spacing: 10) {
        Field(label: "Address", text: $host.hostname, placeholder: "10.0.0.4")
        Field(label: "Port", text: portText).frame(width: 74)
      }

      Field(label: "User", text: $host.username)

      VStack(alignment: .leading, spacing: 5) {
        Text("Private key")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Theme.subtle)

        HStack(spacing: 8) {
          Text(host.keyPath.map(shorten) ?? "None")
            .font(.system(size: 12, design: host.keyPath == nil ? .default : .monospaced))
            .foregroundStyle(host.keyPath == nil ? Theme.subtle : Theme.text)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)

          if host.keyPath != nil {
            Button("Clear") { host.keyPath = nil }
              .buttonStyle(.plain)
              .font(.system(size: 12))
              .foregroundStyle(Theme.subtle)
          }

          Button("Choose\u{2026}") { picking = true }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke, lineWidth: 1))
      }

      Text("Only connection details are saved. Passwords are requested when you connect.")
        .font(.system(size: 11))
        .foregroundStyle(Theme.subtle)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button("Cancel") { dismiss() }
          .buttonStyle(QuietButton())
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(isNew ? "Add host" : "Save") {
          var saved = host
          saved.label =
            host.label.trimmingCharacters(in: .whitespaces).isEmpty
            ? host.hostname : host.label
          onSave(saved)
          dismiss()
        }
        .buttonStyle(FilledButton())
        .disabled(!canSave)
        .keyboardShortcut(.defaultAction)
      }
    }
    .fileImporter(
      isPresented: $picking,
      allowedContentTypes: [.data],
      allowsMultipleSelection: false,
      onCompletion: adoptKey)
    .padding(24)
    .frame(width: 400)
    .background(Theme.sidebar)

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

    host.keyPath = url.path
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

/// Asks for the credential, once, at the moment of connecting.
struct ConnectSheet: View {
  let host: Host
  let onConnect: (String) -> Void

  @State private var password = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 7)
          .fill(Theme.tile(for: host.label.isEmpty ? host.hostname : host.label))
          .frame(width: 34, height: 34)
          .overlay(
            Text(host.initial)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.white))

        VStack(alignment: .leading, spacing: 1) {
          Text(host.label.isEmpty ? host.hostname : host.label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
          Text(host.address)
            .font(.system(size: 11))
            .foregroundStyle(Theme.subtle)
        }
      }

      Field(label: "Password", text: $password, secure: true)

      Text(
        "Leave it empty and the server will ask instead — which is what a host wanting a one-time code will do."
      )
      .font(.system(size: 11))
      .foregroundStyle(Theme.subtle)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button("Cancel") { dismiss() }
          .buttonStyle(QuietButton())
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Connect") {
          onConnect(password)
          dismiss()
        }
        .buttonStyle(FilledButton())
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 380)
    .background(Theme.sidebar)

  }
}
