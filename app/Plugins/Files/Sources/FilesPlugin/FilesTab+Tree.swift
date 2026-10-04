import Foundation
import Tether

/// One row of the tree: an entry, and how deep under the root it is.
struct TreeRow: Identifiable, Equatable {
  let entry: FileEntry
  let depth: Int
  var id: String { entry.path }
}

/// The browser as a tree, the way an editor's explorer is: a folder opens in
/// place, under its name, instead of replacing what is shown. Contents are
/// listed the first time a folder opens and kept while it stays open.
extension FilesTab {
  /// Every row the tree shows, in order: the root's entries, and under each
  /// open folder whose contents have arrived, its own, one level deeper.
  var rows: [TreeRow] {
    guard let directory else { return [] }
    var rows: [TreeRow] = []
    func add(_ path: String, depth: Int) {
      for entry in shown(listings[path] ?? []) {
        rows.append(TreeRow(entry: entry, depth: depth))
        if entry.kind == .directory, expanded.contains(entry.path) {
          add(entry.path, depth: depth + 1)
        }
      }
    }
    add(directory, depth: 0)
    return rows
  }

  func isExpanded(_ entry: FileEntry) -> Bool {
    entry.kind == .directory && expanded.contains(entry.path)
  }

  /// Opens a folder in place, or closes it.
  func toggle(_ entry: FileEntry) {
    guard entry.kind == .directory else { return }
    if expanded.contains(entry.path) {
      collapse(entry)
    } else {
      Task { await expand(entry) }
    }
  }

  func expand(_ entry: FileEntry) async {
    guard entry.kind == .directory else { return }
    expanded.insert(entry.path)
    guard listings[entry.path] == nil else { return }
    opening.insert(entry.path)
    defer { opening.remove(entry.path) }
    do {
      listings[entry.path] = FilesTab.sorted(try await source().list(entry.path))
    } catch {
      expanded.remove(entry.path)
      problem = describe(error)
    }
  }

  /// Closes a folder, and forgets what was listed under it: opening it again
  /// lists it fresh, which is what someone reopening a folder expects.
  func collapse(_ entry: FileEntry) {
    forget(entry.path)
    selection = selection.filter { !$0.hasPrefix(entry.path + "/") }
  }

  /// Moves through visible rows, including children of expanded folders.
  func moveSelection(forward: Bool, steps: Int = 1) {
    let visible = rows.map(\.id)
    guard !visible.isEmpty else { selection = []; return }
    let selected = visible.indices.filter { selection.contains(visible[$0]) }
    guard let index = forward ? selected.last : selected.first else {
      selection = [forward ? visible[0] : visible[visible.count - 1]]
      return
    }
    let next = min(visible.count - 1, max(0, index + (forward ? max(1, steps) : -max(1, steps))))
    selection = [visible[next]]
  }

  /// → : opens the selected folder, or moves into it once it is open.
  func expandOrDescend() {
    guard selection.count == 1, let entry = selection.first.flatMap(entry) else { return }
    guard entry.kind == .directory else { return }
    if isExpanded(entry) {
      if let first = shown(listings[entry.path] ?? []).first { selection = [first.path] }
    } else {
      Task { await expand(entry) }
    }
  }

  /// ← : closes the selected folder, or moves to the folder it is in.
  func collapseOrAscend() {
    guard selection.count == 1, let entry = selection.first.flatMap(entry) else { return }
    if isExpanded(entry) {
      collapse(entry)
    } else if Paths.parent(entry.path) != directory, let parent = self.entry(Paths.parent(entry.path)) {
      selection = [parent.path]
    }
  }

  /// Where something new goes: into the one selected folder, beside the one
  /// selected file, or into the root.
  var targetDirectory: String? {
    guard selection.count == 1, let entry = selection.first.flatMap(entry) else { return directory }
    return entry.kind == .directory ? entry.path : Paths.parent(entry.path)
  }

  /// Shows an entry in the tree: opening the folders between the root and
  /// it when it is under the root, moving the root to its folder otherwise.
  func show(_ entry: FileEntry) async {
    let parent = Paths.parent(entry.path)
    if let root = directory, parent == root || parent.hasPrefix(root == "/" ? "/" : root + "/") {
      for folder in Paths.ancestors(parent) where folder.count > root.count {
        if let known = self.entry(folder) { await expand(known) }
      }
    } else {
      await go(to: parent)
    }
    selection = [entry.path]
  }

  /// Lists these directories again wherever the tree shows them.
  func relist(_ directories: Set<String>) async {
    for path in directories.sorted() where path == directory || expanded.contains(path) {
      if path == directory {
        await go(to: path, remember: false)
      } else if let listed = try? await source().list(path) {
        listings[path] = FilesTab.sorted(listed)
      } else {
        forget(path)
      }
    }
    selection = selection.filter { entry($0) != nil }
  }

  /// Drops a folder, and everything open under it, from the tree.
  func forget(_ path: String) {
    expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
    listings = listings.filter { key, _ in key == directory || (key != path && !key.hasPrefix(path + "/")) }
  }
}
