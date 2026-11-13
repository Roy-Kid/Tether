import Foundation
#if os(macOS)
import AppKit
import TetherUI

/// Opens a path with whichever application the system uses for it.
enum OpenPath {
  /// `raw` as a file on this machine. `~` is this account's home. A relative
  /// path is joined to `workingDirectory` only when that directory is absolute.
  /// A string that is not a path is nil.
  static func fileURL(from raw: String, workingDirectory: String?) -> URL? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.allSatisfy({ !$0.isNewline }) else { return nil }
    if text.hasPrefix("file:") {
      guard let url = URL(string: text), url.isFileURL, !url.path.isEmpty else { return nil }
      return URL(fileURLWithPath: url.path).standardizedFileURL
    }
    let path: String
    if text == "~" || text.hasPrefix("~/") {
      let rest = text == "~" ? "" : String(text.dropFirst(1))
      path = NSHomeDirectory() + rest
    } else if text.hasPrefix("/") {
      path = text
    } else if let workingDirectory, workingDirectory.hasPrefix("/") {
      path = URL(fileURLWithPath: workingDirectory, isDirectory: true).appending(path: text).path
    } else {
      return nil
    }
    return URL(fileURLWithPath: path).standardizedFileURL
  }

  /// Pasteboard text worth offering as the path, or empty.
  static func suggestion(from pasteboard: String?, workingDirectory: String?) -> String {
    guard let pasteboard else { return "" }
    let text = pasteboard.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("file:") || text.contains("/")
    else { return "" }
    guard fileURL(from: text, workingDirectory: workingDirectory) != nil else { return "" }
    return text
  }

  /// Asks for a path and opens it. The application is the one Launch Services
  /// would use; a missing path is reported here and nowhere else.
  @MainActor
  static func ask(workingDirectory: String?, interaction: WorkspaceInteraction? = nil) async {
    let generation = interaction?.lifecycleGeneration
    @MainActor func current() -> Bool {
      !Task.isCancelled && (generation.map { interaction?.workIsCurrent($0) == true } ?? true)
    }
    guard current() else { return }
    let pasted = NSPasteboard.general.string(forType: .string)
    let dialog = Dialog.input(
      "Open Path",
      field: Dialog.Field("Path", initial: suggestion(from: pasted, workingDirectory: workingDirectory)),
      verb: "Open",
      perform: { _ in })
    let reply = await ask(dialog, interaction: interaction)
    guard current(), reply?.role == .confirm else { return }
    let typed = reply?.values.first ?? ""
    guard let url = fileURL(from: typed, workingDirectory: workingDirectory),
      FileManager.default.fileExists(atPath: url.path)
    else {
      await ask(Dialog.notice("Not found"), interaction: interaction)
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.promptsUserIfNeeded = false
    let opened = await withCheckedContinuation { continuation in
      NSWorkspace.shared.open(url, configuration: configuration) { application, _ in
        continuation.resume(returning: application != nil)
      }
    }
    if current(), !opened {
      await ask(Dialog.notice("Can't open"), interaction: interaction)
    }
  }

  @MainActor @discardableResult
  private static func ask(_ dialog: Dialog, interaction: WorkspaceInteraction?) async -> DialogReply? {
    if let interaction { return await interaction.askDialog(dialog) }
    return await DialogPresenter.ask(dialog)
  }
}
#endif
