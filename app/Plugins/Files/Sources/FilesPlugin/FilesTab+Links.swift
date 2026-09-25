import SwiftUI
import Tether
import TetherPluginKit
import TetherUI

#if os(macOS)
  import AppKit
#endif

/// A path someone pointed at in the terminal.
///
/// What was printed is not yet a file. An agent prints `src/plot.png`
/// relative to wherever it was started, which is usually where the shell
/// last said it was, sometimes where the browser is, occasionally home. Each
/// is asked in turn, and only a path the far side says exists is shown —
/// a guess that opened the wrong file would be worse than nothing.
extension FilesTab {
  public func actions(for pointed: PointedLink) -> LinkActions? {
    guard canReachFiles, let path = FilesTab.printedPath(pointed.link) else { return nil }
    let printed = Printed(path: path, directory: pointed.directory)
    var commands = [
      PluginCommand(id: "quickLook", title: "Quick Look", symbol: "eye") { [weak self] in
        Task { await self?.look(at: printed) }
      },
      PluginCommand(id: "reveal", title: "Show in Files", symbol: "folder") { [weak self] in
        Task { await self?.reveal(printed) }
      },
    ]
    #if os(macOS)
      commands += [
        PluginCommand(id: "open", title: "Open", symbol: "arrow.up.forward.app") { [weak self] in
          Task { await self?.withResolved(printed) { self?.openExternally([$0]) } }
        },
        PluginCommand(id: "save", title: "Save to Downloads", symbol: "arrow.down.circle") {
          [weak self] in
          Task { await self?.withResolved(printed) { self?.saveToDownloads([$0]) } }
        },
      ]
    #endif
    return LinkActions(
      open: { [weak self] in Task { await self?.look(at: printed) } },
      preview: { [weak self] in AnyView(LinkPreview(model: self, printed: printed)) },
      commands: commands,
      exists: { [weak self] in await self?.resolve(printed) != nil })
  }

  /// The path a link names, as printed: a path, or a `file://` hyperlink's.
  /// A web address is not a file.
  static func printedPath(_ link: TerminalLink) -> String? {
    switch link.kind {
    case .path(let path, _, _):
      return path
    case .hyperlink(let uri):
      guard let url = URL(string: uri), url.scheme == "file", !url.path.isEmpty else { return nil }
      return url.path
    case .url:
      return nil
    }
  }

  /// Where a printed path could be, most likely first: where the program
  /// that printed it was, where the browser is, home.
  func candidates(for printed: Printed) async -> [String] {
    let path = printed.path
    if path.hasPrefix("/") { return [path] }
    let home = try? await source().home()
    if path == "~" { return home.map { [$0] } ?? [] }
    if path.hasPrefix("~/") {
      return home.map { [Paths.join($0, String(path.dropFirst(2)))] } ?? []
    }
    let relative = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    var bases: [String] = []
    for base in [await printed.directory(), directory, home].compactMap({ $0 })
    where !bases.contains(base) {
      bases.append(base)
    }
    return bases.map { Paths.join($0, relative) }
  }

  /// The first candidate the far side says is there, looked through if it
  /// is a link. Remembered for a moment: a hover asks, and the click that
  /// follows asks again.
  func resolve(_ printed: Printed) async -> FileEntry? {
    let candidates = await candidates(for: printed)
    let key = candidates.joined(separator: "\n")
    if let (when, entry) = resolved[key], Date.now.timeIntervalSince(when) < FilesTab.resolvedFor {
      return entry
    }
    var found: FileEntry?
    for candidate in candidates {
      if let entry = try? await source().stat(candidate) {
        found = entry
        break
      }
    }
    resolved[key] = (Date.now, found)
    return found
  }

  /// ⌘-click, a force click, or tapping the preview: a file opens in Quick
  /// Look, a directory in the browser.
  func look(at printed: Printed) async {
    guard let entry = await resolve(printed) else { return missing() }
    if entry.kind == .directory {
      await reveal(printed)
    } else {
      tab.focus()
      tab.showAccessory()
      await preview([entry])
    }
  }

  /// Shows the path in the browser: its directory, with it selected.
  func reveal(_ printed: Printed) async {
    guard let entry = await resolve(printed) else { return missing() }
    tab.focus()
    tab.showAccessory()
    #if os(macOS)
      // A tree: opened down to it, the root left where it was when it is
      // under the root.
      await show(entry)
      if entry.kind == .directory { await expand(entry) }
    #else
      if entry.kind == .directory {
        await go(to: entry.path)
      } else {
        await go(to: Paths.parent(entry.path))
        selection = [entry.path]
      }
    #endif
  }

  private func withResolved(_ printed: Printed, _ body: (FileEntry) -> Void) async {
    guard let entry = await resolve(printed), entry.kind == .file else { return missing() }
    body(entry)
  }

  /// Nothing by that name anywhere it could be. A Mac says so the way it
  /// says "no" to any other click; a phone's menu simply does nothing.
  private func missing() {
    #if os(macOS)
      NSSound.beep()
    #endif
  }
}

/// A path as printed, and how to learn where it was printed from.
struct Printed {
  let path: String
  let directory: @MainActor () async -> String?

  /// Printed at a prompt whose directory is `directory`, or unknown.
  static func at(_ path: String, in directory: String? = nil) -> Printed {
    Printed(path: path, directory: { directory })
  }
}

/// What a long-press shows above its menu: the file itself when it is small
/// enough to fetch for a look, its symbol and name otherwise.
struct LinkPreview: View {
  /// Fetched for a preview without asking. Past this, the symbol will do.
  static let fetchLimit: UInt64 = 32 * 1024 * 1024

  let model: FilesTab?
  let printed: Printed
  @State private var entry: FileEntry?
  @State private var url: URL?
  @State private var looked = false

  var body: some View {
    VStack(spacing: UIStyle.Space.group) {
      if !looked {
        ProgressView()
          .frame(minWidth: 240, minHeight: 200)
      } else {
        FilePreview(
          name: entry?.name ?? Paths.name(printed.path),
          kind: entry?.kind ?? .file,
          url: url,
          side: 320
        )
      }
      Text(Names.display(entry?.name ?? Paths.name(printed.path)))
        .font(UIStyle.detail)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(UIStyle.Space.section)
    .frame(minWidth: 240, minHeight: 200)
    .task {
      defer { looked = true }
      guard let model, let found = await model.resolve(printed) else { return }
      entry = found
      guard found.kind == .file, found.size <= LinkPreview.fetchLimit else { return }
      url = try? await model.local(found)
    }
  }
}
