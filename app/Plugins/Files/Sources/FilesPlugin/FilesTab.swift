import SwiftUI
import Tether
import TetherPluginKit

#if os(macOS)
  import AppKit
#endif

/// Files on one terminal tab: the directory the browser is in, what is in
/// it, and what is being done to it.
///
/// The file session is opened the first time the browser is shown and kept
/// for the tab's life, beside its shell. A reconnect hands the tab a new
/// lease; the old session is closed and the same directory listed again.
@MainActor @Observable
public final class FilesTab: TabAttachment {
  /// Files at least this large ask before they are fetched for a preview.
  static let previewLimit: UInt64 = 64 * 1024 * 1024
  /// How much the preview cache keeps for one host.
  static let cacheLimit: Int64 = 1024 * 1024 * 1024

  public let tab: TabContext
  let cache: FileCache
  let transfers = Transfers()

  /// Where the browser is. `nil` until the far side has said where home is.
  private(set) var directory: String?
  /// What each listed directory holds, folders first, then by name as
  /// Finder sorts: the root, and every folder the tree has opened.
  var listings: [String: [FileEntry]] = [:]
  /// Folders shown open in the tree, under the root.
  var expanded: Set<String> = []
  /// Folders whose contents are on their way.
  var opening: Set<String> = []
  private(set) var history: [String] = []
  private(set) var loading = false
  /// The one line shown instead of a listing when something failed.
  var problem: String?
  var showHidden = false
  var selection: Set<String> = []
  /// The entry whose name is being edited in place.
  var renaming: String?

  /// What was last handed to Quick Look.
  private(set) var previewed: [URL] = []

  /// Waiting on a person: what to delete, what to do about a name that is
  /// taken, whether to fetch something large.
  var pendingDeletion: [FileEntry] = []
  var conflicts: [Conflict] = []
  var pendingLarge: FileEntry?

  private var connection: RemoteConnection?
  private let opener: (RemoteConnection?) async throws -> any FileSource
  private let presenter: ([URL]) -> Void
  private var session: Task<any FileSource, Error>?
  private var restorationTask: Task<Void, Never>?
  /// Printed paths recently looked for, and what was found.
  var resolved: [String: (Date, FileEntry?)] = [:]
  /// How long a lookup is trusted. Long enough for a hover and its click,
  /// short enough that a file an agent just wrote is found.
  static let resolvedFor: TimeInterval = 3
  /// Bumped by every navigation, so a slow listing that finishes after a
  /// newer one does not put the browser back where it was.
  private var generation = 0

  init(
    tab: TabContext, cache: FileCache? = nil,
    open: @escaping (RemoteConnection?) async throws -> any FileSource = FilesTab.openRemote,
    present: @escaping ([URL]) -> Void = { QuickLook.show($0) }
  ) {
    self.tab = tab
    self.connection = tab.plugin.connection
    self.cache = cache ?? FileCache(host: tab.plugin.hostID)
    self.opener = open
    self.presenter = present
  }

  /// Whether there is anything to ask: a lease to open files on, or a file
  /// session already open.
  var canReachFiles: Bool { connection != nil || session != nil }

  nonisolated static func openRemote(_ connection: RemoteConnection?) async throws
    -> any FileSource
  {
    guard let connection else { throw FileError.disconnected(cause: "No connection.") }
    return try await connection.files()
  }

  // MARK: - TabAttachment

  public var isShowing: Bool { false }
  public var subtitle: String { "" }
  public var isDisconnected: Bool { false }
  public var requiresCloseConfirmation: Bool { transfers.running > 0 }
  public var restorationState: Data? { directory?.data(using: .utf8) }
  public func restore(from state: Data) {
    guard let path = String(data: state, encoding: .utf8) else { return }
    restorationTask?.cancel()
    restorationTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      await self?.go(to: path, remember: false)
    }
  }
  public var closeNote: String? {
    switch transfers.running {
    case 0: nil
    case 1: "1 transfer stops."
    case let count: "\(count) transfers stop."
    }
  }
  public var commands: [PluginCommand] {
    [
      PluginCommand(id: "refresh", title: "Refresh", symbol: "arrow.clockwise") {
        [weak self] in self?.refresh()
      },
      PluginCommand(id: "newFolder", title: "New Folder", symbol: "folder.badge.plus") {
        [weak self] in self?.newFolder()
      },
      PluginCommand(id: "home", title: "Home", symbol: "house") { [weak self] in self?.goHome() },
      PluginCommand(
        id: "hidden", title: showHidden ? "Hide Hidden Files" : "Show Hidden Files",
        symbol: "eye"
      ) { [weak self] in self?.showHidden.toggle() },
    ]
  }
  public func content() -> AnyView { AnyView(EmptyView()) }
  public func inspector() -> AnyView { AnyView(Browser(model: self)) }
  public func accessoryContent() -> AnyView { AnyView(Browser(model: self)) }

  public func connectionChanged(_ connection: RemoteConnection) {
    guard connection !== self.connection else { return }
    self.connection = connection
    let old = session
    session = nil
    Task { await (try? await old?.value)?.close() }
    if directory != nil { refresh() }
  }

  public func close() {
    restorationTask?.cancel()
    restorationTask = nil
    generation += 1
    transfers.cancelAll()
    let old = session
    session = nil
    Task { await (try? await old?.value)?.close() }
  }

  /// Dropped on the terminal: sent to where the shell is, then typed at its
  /// prompt, so a picture reaches a program on the far side in one gesture.
  public func receive(files: [URL]) -> Bool {
    guard canReachFiles, !files.isEmpty else { return false }
    Task {
      let target: String
      if let directory {
        target = directory
      } else if let home = try? await source().home() {
        target = home
      } else {
        return
      }
      let sent = await upload(files, into: target)
      guard !sent.isEmpty else { return }
      tab.insertText(sent.map(Names.shellQuoted).joined(separator: " ") + " ")
    }
    return true
  }

  // MARK: - What is shown

  /// What the root directory holds.
  var entries: [FileEntry] { directory.flatMap { listings[$0] } ?? [] }

  /// The root's entries a person sees: dot-files only when asked for.
  var visible: [FileEntry] { shown(entries) }

  func shown(_ listed: [FileEntry]) -> [FileEntry] {
    showHidden ? listed : listed.filter { !$0.name.hasPrefix(".") }
  }

  /// Anything the browser has listed, wherever in the tree it is.
  func entry(_ path: String) -> FileEntry? {
    if let parent = listings[Paths.parent(path)], let found = parent.first(where: { $0.path == path }) {
      return found
    }
    return listings.values.lazy.flatMap { $0 }.first { $0.path == path }
  }

  var selected: [FileEntry] { selection.sorted().compactMap(entry) }

  // MARK: - Navigation

  /// The first time the browser is shown: where the shell says it is, which
  /// is where whatever it is running is writing; home when it says nothing
  /// or its directory cannot be listed.
  func appear() {
    guard directory == nil, !loading else { return }
    guard let working = tab.workingDirectory() else { return goHome() }
    Task {
      await go(to: working)
      if directory == nil {
        problem = nil
        goHome()
      }
    }
  }

  func goHome() {
    Task {
      do {
        let home = try await source().home()
        await go(to: home)
      } catch {
        problem = describe(error)
      }
    }
  }

  /// Lists `path` and moves there. The directory the browser was in goes on
  /// the back stack unless `remember` is off (a refresh, or going back).
  func go(to path: String, remember: Bool = true) async {
    generation += 1
    let mine = generation
    loading = true
    defer { if mine == generation { loading = false } }
    do {
      let listed = try await source().list(path)
      guard mine == generation, !Task.isCancelled else { return }
      if remember, let directory, directory != path { history.append(directory) }
      directory = path
      listings[path] = FilesTab.sorted(listed)
      // Only what the tree still shows is kept: the root and the open
      // folders under it.
      listings = listings.filter { key, _ in key == path || expanded.contains(key) }
      selection = selection.filter { entry($0) != nil }
      problem = nil
    } catch {
      guard mine == generation else { return }
      problem = describe(error)
    }
  }

  /// Lists the root again, and every folder open under it.
  func refresh() {
    guard let directory else { return appear() }
    Task {
      await go(to: directory, remember: false)
      await relist(expanded)
    }
  }

  func up() {
    guard let directory, directory != "/" else { return }
    Task { await go(to: Paths.parent(directory)) }
  }

  func back() {
    guard let previous = history.popLast() else { return }
    Task { await go(to: previous, remember: false) }
  }

  /// What double-click, return on a phone, or ⌘↓ does.
  func open(_ entry: FileEntry) {
    switch entry.kind {
    case .directory:
      Task { await go(to: entry.path) }
    case .link:
      Task {
        do {
          let target = try await source().stat(entry.path)
          if target.kind == .directory {
            await go(to: entry.path)
          } else {
            await preview([target])
          }
        } catch {
          problem = describe(error)
        }
      }
    case .file:
      Task { await preview([entry]) }
    case .other:
      break
    }
  }

  // MARK: - Preview

  /// Fetches the files and hands them to Quick Look. One larger than
  /// `previewLimit` is asked about first; the rest are shown.
  func preview(_ chosen: [FileEntry], confirmed: Bool = false) async {
    let files = chosen.filter { $0.kind == .file }
    guard !files.isEmpty else { return }
    if !confirmed, let large = files.first(where: { $0.size >= FilesTab.previewLimit }),
      cache.cached(large) == nil
    {
      pendingLarge = large
      return
    }
    guard let filesSource = try? await source() else { return }

    var placeholders: [URL] = []
    #if os(macOS)
      // Open Quick Look before waiting for an uncached remote copy. The
      // placeholder keeps the file's suffix so Quick Look chooses its normal
      // type-specific previewer while the real bytes arrive.
      var initial: [URL] = []
      for file in files {
        if filesSource.isLocal {
          initial.append(URL(fileURLWithPath: file.path))
        } else if let cached = cache.cached(file) {
          initial.append(cached)
        } else if let placeholder = loadingPreview(for: file) {
          placeholders.append(placeholder)
          initial.append(placeholder)
        }
      }
      if !placeholders.isEmpty {
        previewed = initial
        presenter(initial)
      }
    #endif

    var urls: [URL] = []
    for file in files {
      do {
        if filesSource.isLocal {
          urls.append(URL(fileURLWithPath: file.path))
        } else if let cached = cache.cached(file) {
          urls.append(cached)
        } else {
          urls.append(
            try await transfers.download(file, to: cache.location(for: file), from: filesSource))
          cache.trim(to: FilesTab.cacheLimit)
        }
      } catch {
        if (error as? FileError) != .cancelled { problem = describe(error) }
      }
    }
    if !urls.isEmpty {
      previewed = urls
      presenter(urls)
    } else if !placeholders.isEmpty {
      previewed = []
      QuickLook.hide()
    }
    #if os(macOS)
      placeholders.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
    #endif
  }

  #if os(macOS)
    private func loadingPreview(for file: FileEntry) -> URL? {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Tether Preview Loading", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Names.local(file.name))
        try Data("Loading preview…".utf8).write(to: url)
        return url
      } catch {
        return nil
      }
    }
  #endif

  func previewSelection() {
    Task { await preview(selected) }
  }

  /// A copy of `entry` on this machine: the cached one if it is still the
  /// same file, otherwise fetched now.
  func local(_ entry: FileEntry) async throws -> URL {
    // On this machine the far side's path is a path here: shown in place,
    // never copied.
    if try await source().isLocal { return URL(fileURLWithPath: entry.path) }
    if let cached = cache.cached(entry) { return cached }
    let url = try await transfers.download(entry, to: cache.location(for: entry), from: source())
    cache.trim(to: FilesTab.cacheLimit)
    return url
  }

  // MARK: - Changing things

  /// Makes a folder with a name nobody has, and starts renaming it — which
  /// is how Finder does it, and saves asking for a name in a sheet.
  func newFolder() {
    guard let parent = targetDirectory else { return }
    let name = Names.free("untitled folder", taken: Set((listings[parent] ?? []).map(\.name)))
    let path = Paths.join(parent, name)
    Task {
      do {
        try await source().makeDirectory(path)
        if parent != directory { expanded.insert(parent) }
        await relist([parent])
        selection = [path]
        renaming = path
      } catch {
        problem = describe(error)
      }
    }
  }

  /// Gives `entry` a new name in the same directory. A name that is taken
  /// is refused, not replaced: a rename is not the place to lose a file.
  func rename(_ entry: FileEntry, to name: String) async {
    renaming = nil
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != entry.name, !name.contains("/"), name != ".", name != ".."
    else { return }
    let target = Paths.join(Paths.parent(entry.path), name)
    do {
      try await source().rename(entry.path, to: target, replacing: false)
      forget(entry.path)
      await relist([Paths.parent(entry.path)])
      selection = [target]
    } catch {
      problem = describe(error)
    }
  }

  /// Moves entries into another directory on the same machine.
  func move(_ moving: [FileEntry], into destination: String) async {
    for entry in moving where Paths.parent(entry.path) != destination {
      // Into itself would be a loop the server refuses anyway; saying
      // nothing is kinder than relaying its complaint.
      guard entry.path != destination, !destination.hasPrefix(entry.path + "/") else { continue }
      let target = Paths.join(destination, entry.name)
      do {
        try await source().rename(entry.path, to: target, replacing: false)
      } catch FileError.exists {
        conflicts.append(Conflict(name: entry.name, target: target, action: .move(from: entry.path)))
      } catch {
        problem = describe(error)
      }
    }
    moving.forEach { forget($0.path) }
    await relist(Set(moving.map { Paths.parent($0.path) } + [destination]))
  }

  func requestDelete(_ chosen: [FileEntry]) {
    guard !chosen.isEmpty else { return }
    pendingDeletion = chosen
  }

  /// Deletes what was confirmed. A directory goes with everything in it; a
  /// link goes as a link, never what it points at.
  func confirmDelete(_ confirmed: [FileEntry]? = nil) async {
    let doomed = confirmed ?? pendingDeletion
    pendingDeletion = []
    for entry in doomed {
      do {
        if entry.kind == .directory {
          _ = try await source().removeTree(entry.path)
        } else {
          try await source().remove(entry.path)
        }
      } catch {
        problem = describe(error)
        break
      }
    }
    selection.subtract(doomed.map(\.path))
    doomed.forEach { forget($0.path) }
    await relist(Set(doomed.map { Paths.parent($0.path) }))
  }

  // MARK: - Transfers

  /// Sends files from this machine into `destination`, returning the paths
  /// that arrived. A name already there is asked about, not overwritten.
  @discardableResult
  func upload(_ files: [URL], into destination: String) async -> [String] {
    var arrived: [String] = []
    for file in files {
      let target = Paths.join(destination, file.lastPathComponent)
      do {
        if try await exists(target) {
          conflicts.append(
            Conflict(name: file.lastPathComponent, target: target, action: .upload(file)))
          continue
        }
        try await send(file, to: target, replacing: false)
        arrived.append(target)
      } catch {
        if (error as? FileError) != .cancelled { problem = describe(error) }
      }
    }
    await relist([destination])
    return arrived
  }

  /// Settles the first name conflict the way the person chose.
  func resolve(_ conflict: Conflict, _ choice: Conflict.Choice) async {
    conflicts.removeAll { $0.id == conflict.id }
    guard choice != .skip else { return }
    let destination = Paths.parent(conflict.target)
    var target = conflict.target
    if choice == .keepBoth {
      let taken = (try? await source().list(destination).map(\.name)) ?? []
      target = Paths.join(destination, Names.free(conflict.name, taken: Set(taken)))
    }
    let replacing = choice == .replace
    do {
      switch conflict.action {
      case .upload(let file):
        try await send(file, to: target, replacing: replacing)
      case .move(let from):
        try await source().rename(from, to: target, replacing: replacing)
      }
    } catch {
      if (error as? FileError) != .cancelled { problem = describe(error) }
    }
    var touched: Set<String> = [destination]
    if case .move(let from) = conflict.action {
      touched.insert(Paths.parent(from))
      forget(from)
    }
    await relist(touched)
  }

  #if os(macOS)
    /// Opens with whatever this Mac opens the type with. Never something
    /// that would run: those are previewed or saved instead.
    func openExternally(_ files: [FileEntry]) {
      Task {
        for file in files where file.kind == .file && !Names.isRisky(file.name) {
          if let url = try? await local(file) { NSWorkspace.shared.open(url) }
        }
      }
    }

    /// Copies into Downloads under a name nobody there has, and shows them.
    func saveToDownloads(_ files: [FileEntry]) {
      Task {
        let manager = FileManager.default
        let downloads = manager.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var saved: [URL] = []
        for file in files where file.kind == .file {
          guard let copy = try? await local(file) else { continue }
          let taken = Set((try? manager.contentsOfDirectory(atPath: downloads.path)) ?? [])
          let target = downloads.appendingPathComponent(
            Names.free(Names.local(file.name), taken: taken))
          if (try? manager.copyItem(at: copy, to: target)) != nil { saved.append(target) }
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
      }
    }
  #endif

  /// Types the entries' paths at the tab's prompt.
  func insertPaths(_ chosen: [FileEntry]) {
    guard !chosen.isEmpty else { return }
    tab.insertText(chosen.map { Names.shellQuoted($0.path) }.joined(separator: " ") + " ")
  }

  // MARK: - The session

  /// The file session, opened on first use and shared by everything after.
  func source() async throws -> any FileSource {
    if let session { return try await session.value }
    let connection = self.connection
    let opener = self.opener
    let task = Task { try await opener(connection) }
    session = task
    do {
      return try await task.value
    } catch {
      // A failure to open is not kept: the next attempt, after a reconnect
      // or on a network that came back, should try again.
      if session == task { session = nil }
      throw error
    }
  }

  private func exists(_ path: String) async throws -> Bool {
    do {
      _ = try await source().lstat(path)
      return true
    } catch FileError.notFound {
      return false
    }
  }

  private func send(_ file: URL, to target: String, replacing: Bool) async throws {
    // Files chosen from another app's container are lent, not given: the
    // loan has to be open for as long as the copy reads.
    let lent = file.startAccessingSecurityScopedResource()
    defer { if lent { file.stopAccessingSecurityScopedResource() } }
    try await transfers.upload(file, to: target, replacing: replacing, from: source())
  }

  static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
    entries.sorted { a, b in
      let aFolder = a.kind == .directory
      let bFolder = b.kind == .directory
      if aFolder != bFolder { return aFolder }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }
}

/// A name that was already taken, and what was being done when it was.
struct Conflict: Identifiable, Equatable {
  enum Action: Equatable {
    case upload(URL)
    case move(from: String)
  }
  enum Choice: Equatable {
    case replace, keepBoth, skip
  }

  let id = UUID()
  let name: String
  let target: String
  let action: Action
}
