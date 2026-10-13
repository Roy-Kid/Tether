import Foundation
import Observation
import Tether
import TetherPluginKit

#if os(macOS)
  import AppKit
#endif

/// A file opened to be edited: kept beside its copy, so a copy survives the
/// app quitting with its edit not yet written back.
struct EditingRecord: Codable, Equatable, Sendable {
  /// The far side's path and name, which a "save as copy" moves.
  var path: String
  var name: String
  /// Where the copy is, under the host's editing root: a folder of its own
  /// and the name the editor opened. Neither ever changes — the editor holds
  /// that path for as long as the document is open.
  let folder: String
  let localName: String
  /// The far side's file when the copy last matched it.
  var size: UInt64
  var modified: UInt64?
  /// The copy when it last matched the far side. Anything else is an edit
  /// not yet written back.
  var localSize: Int64
  var localModified: Date
  /// The app it was opened in: its quitting is how a closed editor shows.
  var editor: String?
  /// When it was opened, so an editor still on its way is not taken for one
  /// that has gone.
  var opened: Date

  /// What the far side's file must still be for a write-back to land.
  var expected: FileEntry {
    FileEntry(name: name, path: path, kind: .file, size: size, modified: modified, permissions: 0)
  }
}

/// Files of one host opened to be edited here and written back when saved
/// (`LocalCopies.editing`). One per host, shared by every Files tab on it,
/// so a file is one copy and one writer whichever tab opened it.
///
/// A copy goes when it holds nothing that is not on the far side and its
/// editor has gone: the app quit, or — once no tab on the host is left — it
/// is not running. One with an edit still to write back stays until that
/// edit lands or the person discards it, across launches.
@MainActor @Observable
final class EditingCopies {
  enum State: Equatable {
    case synced
    case writing
    /// An edit waiting for a connection, and why the last try failed.
    case pending(String?)
    /// The far side changed too; the person is deciding, or put it off.
    case conflict
  }

  private static var byHost: [UUID: EditingCopies] = [:]

  /// The host's copies, read from disk the first time they are asked for.
  static func shared(host: UUID, label: String) -> EditingCopies {
    if let existing = byHost[host] { return existing }
    let made = EditingCopies(host: host, label: label)
    byHost[host] = made
    return made
  }

  let host: UUID
  let root: URL
  var label: String
  private(set) var records: [String: EditingRecord] = [:]
  private(set) var states: [String: State] = [:]
  /// Whether an app is running; a test says instead.
  var isRunning: @MainActor (String) -> Bool = EditingCopies.running
  /// How long a copy is left quiet before it is written back: an editor
  /// saving writes more than once.
  var settle: Duration = .seconds(1)
  /// How long a write-back that failed waits before trying again.
  var retry: Duration = .seconds(30)
  /// How long an editor is given to report in before a copy with none is
  /// taken for closed.
  static let editorGrace: TimeInterval = 60

  private struct Writer {
    let source: @MainActor () async throws -> any FileSource
    let transfers: Transfers
    /// How a conflict is put to the person: through the tab's plugin
    /// services, as every question a plugin asks is.
    let ask: @MainActor (PluginPrompt) async -> PluginAnswer
  }
  /// The open tabs on this host, any of which can write a copy back.
  private var writers: [UUID: Writer] = [:]

  private struct Watch {
    let folder: any DispatchSourceFileSystemObject
    var file: (any DispatchSourceFileSystemObject)?
  }
  private var watches: [String: Watch] = [:]
  /// A wait before a check, cancelled by a newer save. Never a check that
  /// has started: that runs to the end.
  private var waiting: [String: Task<Void, Never>] = [:]
  /// One check per path at a time; a save during one asks for another after.
  private var running: Set<String> = []
  private var again: Set<String> = []
  /// Copies this side is writing itself — a fetch, a discard — whose
  /// changes are not edits.
  private var quiet: Set<String> = []

  init(host: UUID, label: String, base: URL = LocalCopies.editing) {
    self.host = host
    self.label = label
    root = base.appendingPathComponent(host.uuidString, isDirectory: true)
    load()
    Self.watchTerminations()
  }

  // MARK: - Opening

  /// Where `entry` is edited: its existing copy, or a new folder of its own.
  /// The folder is made; the file is not.
  func location(for entry: FileEntry) throws -> URL {
    if let record = records[entry.path] {
      return try LocalCopies.privateDirectory(root.appendingPathComponent(record.folder, isDirectory: true))
        .appendingPathComponent(record.localName)
    }
    let folder = try LocalCopies.scratch(in: root)
    return folder.appendingPathComponent(Names.local(entry.name))
  }

  /// The copy to open again rather than fetch: one with an edit still to
  /// write back, or one that matches the far side as it is now.
  func reusable(_ current: FileEntry) -> URL? {
    guard let record = records[current.path], let url = copy(of: record) else { return nil }
    if !matches(record, url) { return url }
    return record.size == current.size && record.modified == current.modified ? url : nil
  }

  /// Runs `body`, which writes the copy of `path` itself, without taking
  /// what it writes for an edit.
  func writingCopy<T>(_ path: String, _ body: () async throws -> T) async rethrows -> T {
    quiet.insert(path)
    defer {
      quiet.remove(path)
      if let record = records[path] { rearm(record) }
    }
    return try await body()
  }

  /// Takes a copy just fetched to `url` as `entry`, and starts watching it.
  func adopt(_ entry: FileEntry, at url: URL) {
    LocalCopies.seal(url)
    guard let stamp = Self.stamp(url) else { return }
    let record = EditingRecord(
      path: entry.path, name: entry.name, folder: url.deletingLastPathComponent().lastPathComponent,
      localName: url.lastPathComponent, size: entry.size, modified: entry.modified,
      localSize: stamp.size, localModified: stamp.modified, editor: records[entry.path]?.editor,
      opened: Date())
    store(record)
    states[entry.path] = .synced
    watch(record)
  }

  /// The app the copy opened in.
  func opened(_ path: String, in editor: String?) {
    guard var record = records[path], let editor else { return }
    record.editor = editor
    store(record)
  }

  // MARK: - Writing back

  /// Writes the copy of `path` back if it holds an edit, through an open
  /// tab on the host; with none, it waits for one. One at a time: a save
  /// while a check runs is checked once that one is done.
  func check(_ path: String) async {
    guard !running.contains(path) else {
      again.insert(path)
      return
    }
    running.insert(path)
    defer {
      running.remove(path)
      if again.remove(path) != nil { schedule(path) }
    }
    await writeBack(path)
  }

  private func writeBack(_ path: String) async {
    guard var record = records[path], let url = copy(of: record) else { return }
    guard let stamp = Self.stamp(url), !matches(record, url) else {
      states[path] = .synced
      return
    }
    guard !writers.isEmpty else {
      states[path] = .pending(nil)
      return
    }
    states[path] = .writing
    var failure: String?
    for writer in writers.values {
      do {
        let source = try await writer.source()
        let written = try await writer.transfers.writeBack(url, expected: record.expected, from: source)
        record = records[path] ?? record
        record.size = written.size
        record.modified = written.modified
        record.localSize = stamp.size
        record.localModified = stamp.modified
        store(record)
        states[path] = .synced
        // Saved again while the bytes were on their way.
        if !matches(record, url) { again.insert(path) }
        return
      } catch FileError.changed {
        states[path] = .conflict
        await resolve(path, through: writer)
        return
      } catch {
        failure = describe(error)
      }
    }
    states[path] = .pending(failure)
    schedule(path, after: retry)
  }

  /// Both sides changed. Replace the far side, keep this copy beside it
  /// under a new name, or take the far side's and drop this edit. Later
  /// leaves it to the next save.
  private func resolve(_ path: String, through writer: Writer) async {
    guard let record = records[path], let url = copy(of: record) else { return }
    let prompt = PluginPrompt.choose(
      "“\(Names.display(record.name))” Changed on \(label)",
      actions: [
        PluginAction(id: "replace", title: "Replace"),
        PluginAction(id: "copy", title: "Save as Copy"),
        PluginAction(id: "discard", title: "Discard My Changes", destructive: true),
      ],
      cancel: "Later")
    let answer = await writer.ask(prompt)
    do {
      let source = try await writer.source()
      switch answer.action {
      case "replace":
        var forced = record
        let current = try await source.stat(record.path)
        forced.size = current.size
        forced.modified = current.modified
        store(forced)
        await writeBack(path)
      case "copy":
        try await saveAsCopy(record, url, source: source, transfers: writer.transfers)
      case "discard":
        let current = try await source.stat(record.path)
        try await writingCopy(path) {
          _ = try await writer.transfers.download(current, to: url, from: source)
        }
        adopt(current, at: url)
      default:
        return
      }
    } catch {
      states[path] = .pending(describe(error))
    }
  }

  /// Uploads the copy as a new file beside the one that changed, and edits
  /// that from now on: the editor keeps its document, and its next save goes
  /// to the copy rather than over the other person's change.
  private func saveAsCopy(
    _ record: EditingRecord, _ url: URL, source: any FileSource, transfers: Transfers
  ) async throws {
    let directory = Paths.parent(record.path)
    let taken = Set(try await source.list(directory).map(\.name))
    let name = Names.free(Names.edited(record.name), taken: taken)
    let path = Paths.join(directory, name)
    try await transfers.upload(url, to: path, replacing: false, from: source)
    let uploaded = try await source.stat(path)
    forget(record.path, keepingCopy: true)
    var moved = record
    moved.path = path
    moved.name = name
    moved.size = uploaded.size
    moved.modified = uploaded.modified
    if let stamp = Self.stamp(url) {
      moved.localSize = stamp.size
      moved.localModified = stamp.modified
    }
    store(moved)
    states[path] = .synced
    watch(moved)
  }

  // MARK: - Tabs and editors

  /// A tab on this host that can write copies back. An edit that was
  /// waiting for one goes now.
  func attach(
    tab: UUID, source: @escaping @MainActor () async throws -> any FileSource, transfers: Transfers,
    ask: @escaping @MainActor (PluginPrompt) async -> PluginAnswer
  ) {
    writers[tab] = Writer(source: source, transfers: transfers, ask: ask)
    for (path, state) in states {
      if case .pending = state { schedule(path, after: .zero) }
    }
  }

  /// The last tab on the host gone: copies with nothing left to write back
  /// go, unless their editor is still open on them.
  func detach(tab: UUID) {
    writers[tab] = nil
    if writers.isEmpty { release() }
  }

  /// An app quit: the copies it had open go, if they hold nothing unsent —
  /// unless another process of the same app is still running, which may be
  /// the one with the copy open.
  func editorQuit(_ bundleID: String, othersRunning: Bool = false) {
    guard !othersRunning else { return }
    for record in records.values where record.editor == bundleID { removeIfWritten(record) }
  }

  /// Copies whose editor is not running and that hold nothing unsent. One
  /// whose editor has not reported in yet is given a minute to.
  func release(now: Date = Date()) {
    for record in records.values {
      if let editor = record.editor {
        if isRunning(editor) { continue }
      } else if now.timeIntervalSince(record.opened) < Self.editorGrace {
        continue
      }
      removeIfWritten(record)
    }
  }

  private func removeIfWritten(_ record: EditingRecord) {
    guard let url = copy(of: record) else {
      forget(record.path, keepingCopy: false)
      return
    }
    guard matches(record, url), !running.contains(record.path), !quiet.contains(record.path) else { return }
    forget(record.path, keepingCopy: false)
  }

  // MARK: - Watching

  /// Watches the copy and its folder. The file, for an editor that writes
  /// the same file again; the folder, for one that writes a new file and
  /// renames it over the old — which replaces the file the first watch was
  /// on, so that watch is made again.
  private func watch(_ record: EditingRecord) {
    guard watches[record.path] == nil else { return }
    let folder = root.appendingPathComponent(record.folder, isDirectory: true)
    guard let source = Self.source(folder.path, on: { [weak self] _ in self?.changed(folder: record.folder) })
    else { return }
    watches[record.path] = Watch(folder: source, file: nil)
    rearm(record)
  }

  /// A fresh watch on the copy as it is now.
  private func rearm(_ record: EditingRecord) {
    guard var watch = watches[record.path] else { return }
    watch.file?.cancel()
    let file = root.appendingPathComponent(record.folder, isDirectory: true)
      .appendingPathComponent(record.localName)
    watch.file = Self.source(file.path) { [weak self] _ in self?.changed(folder: record.folder) }
    watches[record.path] = watch
  }

  private func changed(folder: String) {
    guard let record = records.values.first(where: { $0.folder == folder }) else { return }
    guard !quiet.contains(record.path) else { return }
    rearm(record)
    schedule(record.path)
  }

  private func schedule(_ path: String, after delay: Duration? = nil) {
    guard !quiet.contains(path) else { return }
    if running.contains(path) {
      again.insert(path)
      return
    }
    waiting[path]?.cancel()
    let wait = delay ?? settle
    waiting[path] = Task { [weak self] in
      try? await Task.sleep(for: wait)
      guard !Task.isCancelled, let self else { return }
      self.waiting[path] = nil
      await self.check(path)
    }
  }

  private static func source(
    _ path: String, on event: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
  ) -> (any DispatchSourceFileSystemObject)? {
    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
    source.setEventHandler { [weak source] in
      guard let data = source?.data else { return }
      MainActor.assumeIsolated { event(data) }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    return source
  }

  // MARK: - Records

  private func store(_ record: EditingRecord) {
    records[record.path] = record
    try? LocalCopies.privateDirectory(root)
    let file = root.appendingPathComponent(record.folder + ".json")
    if let data = try? JSONEncoder().encode(record) {
      try? data.write(to: file, options: .atomic)
      LocalCopies.seal(file)
    }
  }

  /// Stops tracking `path`. The copy goes too, unless it moves to another
  /// path (`saveAsCopy`).
  private func forget(_ path: String, keepingCopy: Bool) {
    guard let record = records.removeValue(forKey: path) else { return }
    states[path] = nil
    waiting.removeValue(forKey: path)?.cancel()
    if let watch = watches.removeValue(forKey: path) {
      watch.folder.cancel()
      watch.file?.cancel()
    }
    guard !keepingCopy else { return }
    try? FileManager.default.removeItem(at: root.appendingPathComponent(record.folder, isDirectory: true))
    try? FileManager.default.removeItem(at: root.appendingPathComponent(record.folder + ".json"))
  }

  private func load() {
    let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" {
      guard let data = try? Data(contentsOf: file),
        let record = try? JSONDecoder().decode(EditingRecord.self, from: data)
      else { continue }
      records[record.path] = record
      states[record.path] = copy(of: record).map { matches(record, $0) } == true ? .synced : .pending(nil)
      watch(record)
    }
    release()
  }

  private func copy(of record: EditingRecord) -> URL? {
    let url = root.appendingPathComponent(record.folder, isDirectory: true)
      .appendingPathComponent(record.localName)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  private func matches(_ record: EditingRecord, _ url: URL) -> Bool {
    guard let stamp = Self.stamp(url) else { return false }
    return stamp.size == record.localSize && stamp.modified == record.localModified
  }

  static func stamp(_ url: URL) -> (size: Int64, modified: Date)? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
      let size = values.fileSize, let modified = values.contentModificationDate
    else { return nil }
    return (Int64(size), modified)
  }

  // MARK: - The system

  private static var watchingTerminations = false

  /// One observer for the process: every host hears which app quit.
  private static func watchTerminations() {
    #if os(macOS)
      guard !watchingTerminations else { return }
      watchingTerminations = true
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let app, let bundleID = app.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
          .contains { $0.processIdentifier != app.processIdentifier && !$0.isTerminated }
        MainActor.assumeIsolated {
          for copies in byHost.values { copies.editorQuit(bundleID, othersRunning: others) }
        }
      }
    #endif
  }

  static func running(_ bundleID: String) -> Bool {
    #if os(macOS)
      !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    #else
      false
    #endif
  }
}
