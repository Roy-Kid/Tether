import Foundation
import SwiftUI
import TetherUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#endif

/// The file browser's two preferences: how large a file must be before a
/// preview or an open asks, and where a download goes when it should not ask.
enum FilesPreferences {
  static let promptKey = "plugin.dev.tether.files.promptMegabytes"
  static let directoryKey = "plugin.dev.tether.files.downloadDirectory"
  static let defaultMegabytes = 50

  /// Bytes above which a remote preview or open asks. Decimal megabytes, the
  /// same counting the size in the dialog uses.
  static func promptBytes(_ defaults: UserDefaults = .standard) -> UInt64 {
    let stored = defaults.object(forKey: promptKey) as? Int ?? defaultMegabytes
    return UInt64(max(stored, 0)) * 1_000_000
  }

  /// The folder a download uses without asking. Empty, missing, or no longer
  /// a folder means ask.
  static func downloadDirectory(_ defaults: UserDefaults = .standard) -> URL? {
    let path = defaults.string(forKey: directoryKey) ?? ""
    guard !path.isEmpty else { return nil }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directory),
      directory.boolValue
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  /// `~/Desktop` reads better than the whole path.
  static func shorten(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard path.hasPrefix(home) else { return path }
    return "~" + path.dropFirst(home.count)
  }
}

/// Rows under the Files switch. The settings form already owns the section.
/// Besides the two preferences, where the previews are and what they take,
/// with the one thing done to them by hand: clearing.
struct FilesSettings: View {
  @AppStorage(FilesPreferences.promptKey) private var megabytes = FilesPreferences.defaultMegabytes
  @AppStorage(FilesPreferences.directoryKey) private var directory = ""
  @State private var picking = false
  /// What is in the field, including while it is empty. The stored number
  /// stays until the field holds a number again.
  @State private var megabytesText = ""
  /// What the previews take on disk; nil until measured.
  @State private var previewBytes: Int64?

  var body: some View {
    VStack(alignment: .leading, spacing: UIStyle.Space.group) {
      HStack(spacing: UIStyle.Space.inline) {
        Text("Ask Above")
        Spacer(minLength: UIStyle.Space.group)
        TextField("50", text: $megabytesText)
          .multilineTextAlignment(.trailing)
          #if os(iOS)
            .keyboardType(.numberPad)
            .textInputAutocapitalization(.never)
          #endif
        Text("MB")
          .foregroundStyle(.secondary)
      }
      .onAppear { megabytesText = String(max(megabytes, 0)) }
      .onChange(of: megabytesText) { _, next in
        let digits = next.filter(\.isNumber)
        if digits != next {
          megabytesText = digits
          return
        }
        if let value = Int(digits) { megabytes = value }
      }
      LabeledContent("Downloads") {
        Text(directory.isEmpty ? "Ask" : FilesPreferences.shorten(directory))
          .lineLimit(1)
          .truncationMode(.middle)
        SettingsAction(directory.isEmpty ? "Choose Folder" : "Change Folder", systemImage: "folder") { picking = true }
        if !directory.isEmpty {
          SettingsAction("Ask Each Time", systemImage: "arrow.uturn.backward") { directory = "" }
        }
      }
      .help(directory.isEmpty ? "Ask for a folder each download" : directory)
      LabeledContent("Previews") {
        Text(FilesPreferences.shorten(LocalCopies.previews().path))
          .lineLimit(1)
          .truncationMode(.middle)
        if let previewBytes {
          Text(ByteCountFormatter.string(fromByteCount: previewBytes, countStyle: .file))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        #if os(macOS)
          SettingsAction("Open in Finder", systemImage: "arrow.up.right.square") { openPreviews() }
        #endif
        SettingsAction("Clear Previews", systemImage: "trash", role: .destructive) { clearPreviews() }
          .disabled(previewBytes == 0)
      }
      .help(LocalCopies.previews().path)
      .task { await measure() }
    }
    .fileImporter(
      isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      directory = url.path
    }
  }

  /// Walked off the main actor: a full cache is a gigabyte of small files.
  private func measure() async {
    previewBytes = await Task.detached(priority: .utility) { LocalCopies.previewBytes() }.value
  }

  /// Quick Look is hidden first: it may be showing a copy about to go.
  private func clearPreviews() {
    QuickLook.hide()
    Task {
      await Task.detached(priority: .utility) { LocalCopies.clearPreviews() }.value
      await measure()
    }
  }

  #if os(macOS)
    /// The folder itself, made if no preview has yet, so there is one to open.
    private func openPreviews() {
      let folder = LocalCopies.previews()
      try? LocalCopies.privateDirectory(folder)
      NSWorkspace.shared.open(folder)
    }
  #endif
}
