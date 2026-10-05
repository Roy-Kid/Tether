import Foundation
import SwiftUI
import TetherUI
import UniformTypeIdentifiers

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
struct FilesSettings: View {
  @AppStorage(FilesPreferences.promptKey) private var megabytes = FilesPreferences.defaultMegabytes
  @AppStorage(FilesPreferences.directoryKey) private var directory = ""
  @State private var picking = false
  /// What is in the field, including while it is empty. The stored number
  /// stays until the field holds a number again.
  @State private var megabytesText = ""

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
      }
      .help(directory.isEmpty ? "Ask for a folder each download" : directory)
      HStack(spacing: UIStyle.Space.inline) {
        Button(directory.isEmpty ? "Choose Folder" : "Change Folder") { picking = true }
        if !directory.isEmpty {
          Button("Ask Each Time") { directory = "" }
        }
      }
      .buttonStyle(.borderless)
    }
    .fileImporter(
      isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      directory = url.path
    }
  }
}
