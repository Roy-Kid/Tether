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
  /// Files larger than this ask before they are fetched. The settings value
  /// wins; this is what a person gets until they change it.
  static let previewLimit: UInt64 = UInt64(FilesPreferences.defaultMegabytes) * 1_000_000

  public let tab: TabContext
  let cache: FileCache
  let transfers = Transfers()

  /// Where the browser is. `nil` until the far side has said where home is.
  private(set) var directory: String?
  /// The account's home, once asked. The path menu uses it to avoid listing
  /// that directory twice.
  private(set) var homeDirectory: String?
  /// Last directory reported by the terminal. Manual browsing stays put
  /// until the terminal moves to another directory.
  private(set) var terminalDirectory: String?
  /// What each listed directory holds, folders first, then by name as
  /// Finder sorts: the root, and every folder the tree has opened.
  var listings: [String: [FileEntry]] = [:]
  /// Folders shown open in the tree, under the root.
  var expanded: Set<String> = []
  /// Folders whose contents are on their way.
  var opening: Set<String> = []
  var openingRequests: [String: UUID] = [:]
  private(set) var history: [String] = []
  private(set) var loading = false
  /// The one line shown instead of a listing when something failed.
  var problem: String?
  var showHidden = false
  var selection: Set<String> = []
  /// The entry whose name is being edited in place.
  var renaming: String?
  /// True until the next turn after a paste was accepted. ⌘V arrives both as
  /// a key and as the Paste menu; one of them has to be the paste.
  private var pasteDelivered = false
  /// The find field occupies the directory name's slot. Closed, the browser
  /// shows the name. ⌃F opens it only while the list or the field has the
  /// keyboard — a shortcut on the window would take ⌃F from the shell.
  var finding = false
  /// Bumped whenever find is asked to take the keyboard, including when it
  /// is already open.
  var findTicket = 0
  /// Bumped when find closes, so the list can take the keyboard back.
  var listTicket = 0
  /// What is typed in the field. A slash or a leading `~` is a path; anything
  /// else names a row already listed.
  var query = ""
  /// Which path submission is the current one. A slower one does not land
  /// after a newer paste.
  var findCommit = 0

  /// What was last handed to Quick Look.
  private(set) var previewed: [URL] = []

  /// Waiting on a person: what to delete, what to do about a name that is
  /// taken, whether to fetch something large, where a download should land.
  var pendingDeletion: [FileEntry] = []
  var conflicts: [Conflict] = []
  var pendingLarge: FileEntry?
  var pendingFetch: PendingFetch?
  var pendingSave: [FileEntry] = []

  private var connection: RemoteConnection?
  private let opener: (RemoteConnection?) async throws -> any FileSource
  private let presenter: ([URL]) -> Void
  let defaults: UserDefaults
  /// Shows files a download just wrote. A test records this instead of opening
  /// a Finder window.
  var revealSaved: @MainActor ([URL]) -> Void = { urls in
    #if os(macOS)
      if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    #endif
  }
  /// Hands a fetched file to the app this machine opens that type with.
  var openLocal: @MainActor (URL) -> Void = { url in
    #if os(macOS)
      NSWorkspace.shared.open(url)
    #endif
  }
  /// The same for a copy opened to be edited, reporting which app took it:
  /// that app quitting is how the copy is known to be closed.
  var openToEdit: @MainActor (URL, @escaping @MainActor (String?) -> Void) -> Void = { url, opened in
    #if os(macOS)
      NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
        let bundleID = app?.bundleIdentifier
        Task { @MainActor in opened(bundleID) }
      }
    #endif
  }
  /// Files opened to be edited on this host, shared with its other tabs.
  let editing: EditingCopies
  /// How this tab puts a question: through its plugin services. A test
  /// answers instead.
  var ask: @MainActor (PluginPrompt) async -> PluginAnswer
  private var session: Task<any FileSource, Error>?
  private var restorationTask: Task<Void, Never>?
  /// Printed paths recently looked for, and what was found.
  var resolved: [String: (Date, FileEntry?)] = [:]
  /// How long a lookup is trusted. Long enough for a hover and its click,
  /// short enough that a file an agent just wrote is found.
  static let resolvedFor: TimeInterval = 3
  /// Bumped by every navigation, so a slow listing that finishes after a
  /// newer one does not put the browser back where it was.
  private(set) var generation = 0

  init(
    tab: TabContext, cache: FileCache? = nil, editing: EditingCopies? = nil,
    open: @escaping (RemoteConnection?) async throws -> any FileSource = FilesTab.openRemote,
    present: @escaping ([URL]) -> Void = { QuickLook.show($0) },
    defaults: UserDefaults = .standard
  ) {
    self.tab = tab
    self.connection = tab.plugin.connection
    self.cache = cache ?? FileCache(host: tab.plugin.hostID)
    // A test hands in a cache of its own and never sweeps the real ones.
    if cache == nil { LocalCopies.sweepOnce() }
    self.opener = open
    self.presenter = present
    self.defaults = defaults
    self.editing = editing ?? EditingCopies.shared(host: tab.plugin.hostID, label: tab.plugin.hostLabel)
    let services = tab.plugin.services
    self.ask = { await services.ask($0) }
    self.editing.attach(
      tab: tab.id,
      source: { [weak self] in
        guard let self else { throw FileError.disconnected(cause: "The tab closed.") }
        return try await self.source()
      },
      transfers: transfers, ask: { [weak self] prompt in await self?.ask(prompt) ?? .cancelled })
  }

  /// Where a download panel opens. The configured folder, or Downloads.
  var preferredDownloadDirectory: URL {
    FilesPreferences.downloadDirectory(defaults)
      ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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
      PluginCommand(id: "find", title: "Find", symbol: "magnifyingglass") {
        [weak self] in self?.beginFind()
      },
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
    // Reading a terminal's connection creates a new wrapper of the same lease.
    guard connection.leaseID() != self.connection?.leaseID() else { return }
    self.connection = connection
    reopen()
  }

  /// Drops the file session and lists again on the lease held now.
  ///
  /// A browser that opened while the tab was still dialling has no directory
  /// yet, and its first listing may still be in flight. That attempt is
  /// talking to the lease that just died; leaving it to finish is how a
  /// reconnect stays on the disconnected session.
  func reopen() {
    let old = session
    session = nil
    generation += 1
    openingRequests.removeAll()
    opening.removeAll()
    loading = false
    Task { await (try? await old?.value)?.close() }
    refresh()
  }

  public func close() {
    restorationTask?.cancel()
    restorationTask = nil
    generation += 1
    openingRequests.removeAll()
    opening.removeAll()
    transfers.cancelAll()
    editing.detach(tab: tab.id)
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
    Task { await learnHome() }
    Task {
      let mine = generation
      let working = await tab.resolveWorkingDirectory(nil)
      guard !Task.isCancelled, mine == generation else { return }
      guard let working else { return goHome() }
      terminalDirectory = working
      await go(to: working)
      if directory == nil {
        problem = nil
        goHome()
      }
    }
  }

  /// Called only while Files is visible. Ignore an answer overtaken by a
  /// manual navigation, and let `go` reject listings overtaken by a newer one.
  func followTerminalDirectory() async {
    let mine = generation
    guard let working = await tab.resolveWorkingDirectory(nil),
      !Task.isCancelled, mine == generation
    else { return }
    let previous = terminalDirectory
    terminalDirectory = working
    guard previous != working, directory != working else { return }
    await go(to: working)
  }

  func learnHome() async {
    guard homeDirectory == nil else { return }
    homeDirectory = try? await source().home()
  }

  /// The path menu's rows: enclosing directories, plus Home or Shell when
  /// those are not already in that list.
  var pathPlaces: PathPlaces {
    PathPlaces(
      directory: directory, home: homeDirectory, shell: terminalDirectory ?? tab.workingDirectory())
  }

  func goHome() {
    Task {
      do {
        let home = try await source().home()
        homeDirectory = home
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
    openingRequests.removeAll()
    opening.removeAll()
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

  /// Where the shell is, when the browser is showing somewhere else. Absent
  /// when they already agree, so the bar does not spend a control on it.
  var shellDirectory: String? {
    guard let working = terminalDirectory ?? tab.workingDirectory(), working != directory else {
      return nil
    }
    return working
  }

  /// Moves to the shell's directory. Back still returns to where the browser was.
  func goToShell() {
    Task {
      guard let working = await tab.resolveWorkingDirectory(nil), !Task.isCancelled else { return }
      terminalDirectory = working
      await go(to: working)
    }
  }

  func beginFind() {
    finding = true
    findTicket += 1
  }

  func closeFind() {
    guard finding || !query.isEmpty else { return }
    finding = false
    query = ""
    listTicket += 1
  }

  /// The field's leading symbol: a name filters, `~` is home, anything else
  /// with a slash is a path taken from the shell's directory.
  var findSymbol: String {
    FindQuery.classify(query)?.symbol ?? "magnifyingglass"
  }

  /// Whether the field is narrowing rows by name, rather than holding a path.
  var findingByName: Bool {
    guard finding, case .name = FindQuery.classify(query) else { return false }
    return true
  }

  /// Rows whose names match the field, when it holds a name. A path leaves
  /// the list alone until it is submitted.
  var displayedRows: [TreeRow] {
    guard finding, case .name(let needle) = FindQuery.classify(query) else { return rows }
    return treeRows(seeingHidden: showHidden || needle.hasPrefix(".")).filter {
      $0.entry.name.range(of: needle, options: .caseInsensitive) != nil
    }
  }

  /// The phone's one directory, filtered the same way.
  var displayed: [FileEntry] {
    guard finding, case .name(let needle) = FindQuery.classify(query) else { return visible }
    let pool = (showHidden || needle.hasPrefix(".")) ? entries : visible
    return pool.filter { $0.name.range(of: needle, options: .caseInsensitive) != nil }
  }

  /// The field changed. A paste of a path is submitted; a typed slash is not,
  /// so a path is not looked up once per character.
  func noteQueryChange(from previous: String) {
    guard finding else { return }
    // A pasted path often arrives with the line break it was copied from.
    // The field drops the break, and this sees the value that had it.
    let arrivedWithBreak = previous.contains(where: \.isNewline) || query.contains(where: \.isNewline)
    if query.contains(where: \.isNewline) {
      query = query.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
    }
    if arrivedWithBreak || FindQuery.pasted(from: previous, to: query),
      case .path = FindQuery.classify(query)
    {
      commitFind()
      return
    }
    guard case .name = FindQuery.classify(query) else { return }
    let items = nameMatches
    if items.isEmpty {
      selection = []
    } else if !items.contains(where: { selection.contains($0.path) }) {
      selection = [items[0].path]
    }
  }

  /// Return in the field. A path is looked up where the shell is; a name
  /// opens the highlighted row.
  func commitFind() {
    switch FindQuery.classify(query) {
    case .path(let text):
      findCommit += 1
      let mine = findCommit
      Task { await revealQuery(text, commit: mine) }
    case .name:
      activateMatch()
    case nil:
      break
    }
  }

  func moveMatch(by delta: Int) {
    guard findingByName else { return }
    let items = nameMatches
    guard !items.isEmpty else { return }
    let index = items.firstIndex { selection.contains($0.path) } ?? (delta > 0 ? -1 : items.count)
    let next = min(max(index + delta, 0), items.count - 1)
    selection = [items[next].path]
  }

  private var nameMatches: [FileEntry] {
    #if os(macOS)
      displayedRows.map(\.entry)
    #else
      displayed
    #endif
  }

  /// Return on a name: a folder opens in place on a Mac, and a file is shown.
  private func activateMatch() {
    guard findingByName else { return }
    let items = nameMatches
    guard let entry = items.first(where: { selection.contains($0.path) }) ?? items.first else { return }
    selection = [entry.path]
    #if os(macOS)
      if entry.kind == .directory {
        Task { await expand(entry) }
      } else {
        open(entry)
      }
    #else
      open(entry)
    #endif
  }
}

/// What the find field is holding. A slash or a leading `~` is a place to
/// go. Anything else is a name already on screen.
enum FindQuery: Equatable {
  case name(String)
  case path(String)

  static func classify(_ raw: String) -> FindQuery? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.hasPrefix("~") || text.contains("/") { return .path(text) }
    return .name(text)
  }

  /// More than one character arrived at once, or a line break came with it.
  /// One typed character, including `/`, is not a paste.
  static func pasted(from previous: String, to next: String) -> Bool {
    if next.contains(where: \.isNewline) { return true }
    return next.count > previous.count + 1
  }

  var symbol: String {
    switch self {
    case .name: "magnifyingglass"
    case .path(let text) where text.hasPrefix("~"): "house"
    case .path: "terminal"
    }
  }
}

extension FilesTab {
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
            await openFile(target)
          }
        } catch {
          problem = describe(error)
        }
      }
    case .file:
      Task { await openFile(entry) }
    case .other:
      break
    }
  }

  // MARK: - Preview

  /// Fetches the files and hands them to Quick Look. One larger than the
  /// size gate is asked about first, when fetching it would actually move
  /// bytes; the rest are shown with it once that is allowed.
  ///
  /// Each file is stated first. The cache key includes that modification
  /// time, so a listing from before the write is not served as the new file.
  func preview(_ chosen: [FileEntry], confirmed: Bool = false) async {
    let chosen = chosen.filter { $0.kind == .file }
    guard !chosen.isEmpty else { return }
    guard let filesSource = try? await source() else { return }
    let files = await identities(chosen, from: filesSource)
    if holdForSize(files, confirmed: confirmed, action: .preview(files), source: filesSource) {
      return
    }

    var placeholders: [URL] = []
    #if os(macOS)
      // Open Quick Look before waiting for an uncached remote copy. The
      // placeholder keeps the file's suffix so Quick Look chooses its normal
      // type-specific previewer while the real bytes arrive.
      var initial: [URL] = []
      for file in files {
        if filesSource.isLocal {
          initial.append(localPreviewCopy(file) ?? URL(fileURLWithPath: file.path))
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
        urls.append(try await urlForPreview(file, from: filesSource))
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
      do {
        let directory = try LocalCopies.scratch(in: LocalCopies.loading())
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

  /// Parks a preview or an open on the size dialog. A file already cached, or
  /// one that lives on this machine, is not a download and is not asked about.
  /// True when the caller should stop and wait.
  private func holdForSize(
    _ files: [FileEntry], confirmed: Bool, action: PendingFetch, source: any FileSource
  ) -> Bool {
    guard !confirmed, !source.isLocal else { return false }
    let limit = FilesPreferences.promptBytes(defaults)
    guard let large = files.first(where: { $0.size > limit && cache.cached($0) == nil }) else {
      return false
    }
    pendingLarge = large
    pendingFetch = action
    return true
  }

  /// A copy of `entry` on this machine: the cached one if it is still the
  /// same file, otherwise fetched now.
  func local(_ entry: FileEntry) async throws -> URL {
    let filesSource = try await source()
    // On this machine the far side's path is a path here: shown in place,
    // never copied. A preview still copies, so Quick Look's URL changes
    // when the file's modification time does.
    if filesSource.isLocal { return URL(fileURLWithPath: entry.path) }
    let current = await identity(entry, from: filesSource)
    if let cached = cache.cached(current) { return cached }
    let url = try await transfers.download(current, to: cache.location(for: current), from: filesSource)
    return cache.keep(url)
  }

  /// What Quick Look should open for `file`, whose size and modification
  /// time are already current.
  private func urlForPreview(_ file: FileEntry, from source: any FileSource) async throws -> URL {
    if source.isLocal {
      return localPreviewCopy(file) ?? URL(fileURLWithPath: file.path)
    }
    if let cached = cache.cached(file) { return cached }
    let url = try await transfers.download(file, to: cache.location(for: file), from: source)
    return cache.keep(url)
  }

  /// A cache copy of a file on this machine, keyed by its modification time,
  /// so a newer file is a different URL. Past the size gate it stays where
  /// it is. Nil when the file is not on disk.
  func localPreviewCopy(_ entry: FileEntry) -> URL? {
    guard entry.size <= FilesPreferences.promptBytes(defaults) else { return nil }
    let sourceURL = URL(fileURLWithPath: entry.path)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
    if let cached = cache.cached(entry) { return cached }
    let destination = cache.location(for: entry)
    do {
      try FileManager.default.copyItem(at: sourceURL, to: destination)
    } catch {
      return nil
    }
    return cache.keep(destination)
  }

  /// The same files, with the size and modification time they have now.
  /// A remote file is stated. A file on this machine is read from disk,
  /// which is the time a preview has to follow.
  func identities(_ entries: [FileEntry], from source: any FileSource) async -> [FileEntry] {
    var current: [FileEntry] = []
    for entry in entries {
      current.append(await identity(entry, from: source))
    }
    return current
  }

  private func identity(_ entry: FileEntry, from source: any FileSource) async -> FileEntry {
    let stated: FileEntry
    if let found = try? await source.stat(entry.path), found.kind == .file {
      stated = found
    } else {
      stated = entry
    }
    guard source.isLocal else { return stated }
    return Self.withDiskModification(stated)
  }

  /// Size and modification time from this machine, in whole seconds — the
  /// same resolution a remote listing reports. Read from the file, not from
  /// a URL's cached resource values.
  static func withDiskModification(_ entry: FileEntry) -> FileEntry {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path) else {
      return entry
    }
    let modified = (attrs[.modificationDate] as? Date).map { UInt64($0.timeIntervalSince1970) }
    let size = (attrs[.size] as? NSNumber)?.uint64Value
    guard modified != nil || size != nil else { return entry }
    return FileEntry(
      name: entry.name, path: entry.path, kind: entry.kind,
      size: size ?? entry.size, modified: modified ?? entry.modified,
      permissions: entry.permissions)
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
    var failure: String?
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
        failure = describe(error)
      }
    }
    moving.forEach { forget($0.path) }
    await relist(Set(moving.map { Paths.parent($0.path) } + [destination]), keeping: failure)
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
    var failure: String?
    for entry in doomed {
      do {
        if entry.kind == .directory {
          _ = try await source().removeTree(entry.path)
        } else {
          try await source().remove(entry.path)
        }
      } catch {
        failure = describe(error)
        break
      }
    }
    selection.subtract(doomed.map(\.path))
    doomed.forEach { forget($0.path) }
    await relist(Set(doomed.map { Paths.parent($0.path) }), keeping: failure)
  }

  // MARK: - Transfers

  /// Files copied on this machine, sent where a new file would go.
  ///
  /// A folder that is not the root is opened so the copies show up in the
  /// tree. Returns whether the paste was accepted: an empty board was not,
  /// and a second delivery of the same ⌘V was already accepted.
  @discardableResult
  func pasteLocalFiles(_ files: [URL]) -> Bool {
    let files = files.filter(\.isFileURL)
    guard !files.isEmpty, let destination = targetDirectory else { return false }
    guard claimPaste() else { return true }
    if destination != directory { expanded.insert(destination) }
    let scoped = files.filter { $0.startAccessingSecurityScopedResource() }
    Task {
      defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
      await upload(files, into: destination)
    }
    return true
  }

  /// One ⌘V is delivered twice, by the key and by the Paste menu.
  private func claimPaste() -> Bool {
    guard !pasteDelivered else { return false }
    pasteDelivered = true
    Task { @MainActor [weak self] in self?.pasteDelivered = false }
    return true
  }

  /// Sends files from this machine into `destination`, returning the paths
  /// that arrived. A name already there is asked about, not overwritten.
  ///
  /// Not stated first. The upload refuses a taken name itself, where it can
  /// tell; a server that will not stat a name that is not there yet must
  /// not stop the file before it has even shown a row.
  @discardableResult
  func upload(_ files: [URL], into destination: String) async -> [String] {
    var arrived: [String] = []
    var failure: String?
    for file in files {
      let target = Paths.join(destination, file.lastPathComponent)
      do {
        try await send(file, to: target, replacing: false)
        arrived.append(target)
      } catch FileError.exists {
        conflicts.append(Conflict(name: file.lastPathComponent, target: target, action: .upload(file)))
      } catch {
        if (error as? FileError) != .cancelled { failure = describe(error) }
      }
    }
    await relist([destination], keeping: failure)
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
    var failure: String?
    do {
      switch conflict.action {
      case .upload(let file):
        try await send(file, to: target, replacing: replacing)
      case .move(let from):
        try await source().rename(from, to: target, replacing: replacing)
      }
    } catch {
      if (error as? FileError) != .cancelled { failure = describe(error) }
    }
    var touched: Set<String> = [destination]
    if case .move(let from) = conflict.action {
      touched.insert(Paths.parent(from))
      forget(from)
    }
    await relist(touched, keeping: failure)
  }

  /// What opening a file does: on a Mac, it is edited in whatever this Mac
  /// opens its type with and written back when saved; a phone has no other
  /// app to write it back from, so it is previewed.
  private func openFile(_ entry: FileEntry) async {
    #if os(macOS)
      await edit([entry])
    #else
      await preview([entry])
    #endif
  }

  func openExternally(_ files: [FileEntry]) {
    Task { await edit(files) }
  }

  /// Opens files to be edited, each in whatever this Mac opens its type with.
  /// The copy stays watched (`EditingCopies`): a save is written back, and a
  /// change on the far side is brought in, as soon as either happens. Never a
  /// file that would run: that is previewed instead. On this machine the
  /// file itself is opened. A large remote file is asked about first, as a
  /// preview is; a copy already here — being edited, or previewed — is not
  /// fetched again.
  func edit(_ files: [FileEntry], confirmed: Bool = false) async {
    let chosen = files.filter { $0.kind == .file }
    let risky = chosen.filter { Names.isRisky($0.name) }
    if !risky.isEmpty { await preview(risky) }
    let editable = chosen.filter { !Names.isRisky($0.name) }
    guard !editable.isEmpty, let filesSource = try? await source() else { return }
    let current = await identities(editable, from: filesSource)
    if filesSource.isLocal {
      current.forEach { openLocal(URL(fileURLWithPath: $0.path)) }
      return
    }
    let unfetched = current.filter { editing.reusable($0) == nil }
    if holdForSize(unfetched, confirmed: confirmed, action: .open(current), source: filesSource) {
      return
    }
    for file in current {
      do {
        let url = try await editingCopy(of: file, from: filesSource)
        let editing = self.editing
        openToEdit(url) { editor in editing.opened(file.path, in: editor) }
      } catch {
        if (error as? FileError) != .cancelled { problem = describe(error) }
      }
    }
  }

  /// The copy `file` is edited in: the one already being edited, the preview
  /// moved over, or fetched now.
  private func editingCopy(of file: FileEntry, from source: any FileSource) async throws -> URL {
    if let reused = editing.reusable(file) { return reused }
    let location = try editing.location(for: file)
    try await editing.writingCopy(file.path) {
      try? FileManager.default.removeItem(at: location)
      if !cache.move(file, to: location) {
        _ = try await transfers.download(file, to: location, from: source)
      }
    }
    editing.adopt(file, at: location)
    return location
  }

  /// Saves the entries where the person asked, or into the folder they set.
  /// No folder yet: the browser asks. A directory goes with what is in it.
  /// A link does not: it is not the thing it names.
  func download(_ entries: [FileEntry]) {
    let saving = entries.filter { $0.kind == .file || $0.kind == .directory }
    guard !saving.isEmpty else { return }
    if let folder = FilesPreferences.downloadDirectory(defaults) {
      Task { await save(saving, to: folder) }
    } else {
      pendingSave = saving
    }
  }

  /// Puts `entries` into `directory`. A remote file that was already previewed
  /// is moved out of the cache; anything else is fetched straight there. A
  /// file on this machine is copied, and left where it is. A directory is
  /// copied with its contents, including an empty one.
  func save(_ entries: [FileEntry], to directory: URL) async {
    let scoped = directory.startAccessingSecurityScopedResource()
    defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
    var saved: [URL] = []
    var seen: Set<String> = []
    for entry in entries where entry.kind == .file || entry.kind == .directory {
      do {
        if let url = try await saveEntry(entry, into: directory, depth: 0, seen: &seen) {
          saved.append(url)
        }
      } catch {
        if (error as? FileError) != .cancelled { problem = describe(error) }
      }
    }
    if !saved.isEmpty { revealSaved(saved) }
  }

  /// How deep a downloaded folder may go. A listing is the far side's data,
  /// and one that names a new directory forever has to stop.
  private static let downloadDepth = 64

  /// One file or directory, under a name not already taken in `directory`.
  /// A path already saved in this download is skipped, so a listing that
  /// repeats itself cannot walk twice.
  private func saveEntry(
    _ entry: FileEntry, into directory: URL, depth: Int, seen: inout Set<String>
  ) async throws -> URL? {
    guard entry.kind == .file || entry.kind == .directory else { return nil }
    guard seen.insert(entry.path).inserted else { return nil }
    if entry.kind == .directory {
      return try await saveDirectory(entry, into: directory, depth: depth, seen: &seen)
    }
    return try await saveFile(entry, into: directory)
  }

  private func saveDirectory(
    _ entry: FileEntry, into directory: URL, depth: Int, seen: inout Set<String>
  ) async throws -> URL? {
    guard depth < Self.downloadDepth else {
      throw FileError.failed(cause: "“\(Names.display(entry.name))” is too deep to download.")
    }
    let filesSource = try await source()
    let target = Self.uniqueDestination(entry.name, in: directory)
    if filesSource.isLocal {
      try FileManager.default.copyItem(at: URL(fileURLWithPath: entry.path), to: target)
      return target
    }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let children: [FileEntry]
    do {
      children = try await filesSource.list(entry.path)
    } catch {
      problem = describe(error)
      return target
    }
    for child in children {
      if Task.isCancelled { return target }
      do {
        _ = try await saveEntry(child, into: target, depth: depth + 1, seen: &seen)
      } catch {
        if (error as? FileError) != .cancelled { problem = describe(error) }
      }
    }
    return target
  }

  /// A remote file that was already previewed is moved out of the cache;
  /// anything else is fetched straight to `directory`. A file on this machine
  /// is copied, and left where it is.
  private func saveFile(_ file: FileEntry, into directory: URL) async throws -> URL {
    let target = Self.uniqueDestination(file.name, in: directory)
    let filesSource = try await source()
    let current = await identity(file, from: filesSource)
    if filesSource.isLocal {
      try FileManager.default.copyItem(at: URL(fileURLWithPath: file.path), to: target)
    } else if cache.move(current, to: target) {
      // The preview copy was the download.
    } else {
      _ = try await transfers.download(current, to: target, from: filesSource)
    }
    return target
  }

  /// `name` in `directory`, or `name 2` when that name is already there.
  private static func uniqueDestination(_ name: String, in directory: URL) -> URL {
    let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    return directory.appendingPathComponent(Names.free(Names.local(name), taken: taken))
  }

  /// What a drag of `entry` takes: the selection, when `entry` is part of
  /// it, as Finder does; otherwise that entry alone.
  func draggedEntries(_ entry: FileEntry) -> [FileEntry] {
    if selection.contains(entry.path) {
      let chosen = selected
      if !chosen.isEmpty { return chosen }
    }
    return [entry]
  }

  /// The paths a drag of `entry` carries. The same text Copy Path would copy.
  func draggedPathText(_ entry: FileEntry) -> String {
    Names.copiedPaths(draggedEntries(entry).map(\.path))
  }

  /// What a drag or a share of `entry` fetches, when something asks for the
  /// bytes. Made here, on the main actor; used from wherever the asking is.
  /// The session is the one open now: a drag that outlives it fails rather
  /// than waiting for the next.
  func fetch(_ entry: FileEntry) -> FileFetch {
    FileFetch(entry: entry, session: session, cache: cache, transfers: transfers)
  }

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

/// A preview or an open parked on the size dialog, with every file it was
/// asked to handle so confirming does not drop the smaller ones.
enum PendingFetch: Equatable {
  case preview([FileEntry])
  case open([FileEntry])
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
