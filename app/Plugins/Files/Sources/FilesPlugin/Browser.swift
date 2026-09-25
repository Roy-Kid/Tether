import SwiftUI
import Tether
import TetherUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#else
  import PhotosUI
  import UIKit
#endif

/// The browser: the inspector column on a Mac, a sheet on a phone.
///
/// Silent chrome (law: app-ui-chrome): the only words in it are the
/// directory's name and the files' own. Controls are symbols with their
/// names on hover; menus, which are not window chrome, use words.
struct Browser: View {
  @Bindable var model: FilesTab
  @State private var importing = false

  var body: some View {
    content
      .task { model.appear() }
      .fileImporter(
        isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true
      ) { result in
        guard case .success(let files) = result, let target = model.targetDirectory else { return }
        Task { await model.upload(files, into: target) }
      }
      .modifier(Confirmations(model: model))
  }

  @ViewBuilder private var content: some View {
    #if os(macOS)
      VStack(spacing: 0) {
        MacHeader(model: model, importing: $importing)
        Divider()
        listing
        TransferList(transfers: model.transfers)
      }
    #else
      NavigationStack {
        listing
          .navigationTitle(model.directory.map(Paths.name).map(Names.display) ?? "")
          .navigationBarTitleDisplayMode(.inline)
          .toolbarTitleMenu { PathMenu(model: model) }
          .toolbar { PhoneToolbar(model: model, importing: $importing) }
          .refreshable { if let directory = model.directory { await model.go(to: directory, remember: false) } }
          .safeAreaInset(edge: .bottom) { TransferList(transfers: model.transfers) }
      }
      .presentationDetents([.medium, .large])
    #endif
  }

  @ViewBuilder private var listing: some View {
    if let problem = model.problem, model.entries.isEmpty {
      Label(problem, systemImage: "exclamationmark.triangle")
        .font(UIStyle.detail)
        .foregroundStyle(Theme.subtle)
        .padding(UIStyle.Space.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      FileList(model: model)
    }
  }
}

/// The entries of the current directory.
private struct FileList: View {
  @Bindable var model: FilesTab
  @FocusState private var listFocused: Bool

  var body: some View {
    List(selection: $model.selection) {
      if let problem = model.problem {
        Label(problem, systemImage: "exclamationmark.triangle")
          .font(UIStyle.detail)
          .foregroundStyle(Theme.subtle)
      }
      #if os(macOS)
        // A tree, as an editor's explorer is: folders open in place.
        ForEach(model.rows) { row in
          FileRow(model: model, entry: row.entry, depth: row.depth)
            .tag(row.entry.path)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        }
      #else
        // A phone drills down: one directory a screen.
        ForEach(model.visible, id: \.path) { entry in
          FileRow(model: model, entry: entry)
            .tag(entry.path)
        }
      #endif
    }
    #if os(macOS)
      .listStyle(.inset)
      .focused($listFocused)
      .onAppear { listFocused = true }
      .environment(\.defaultMinListRowHeight, UIStyle.rowHeight)
      .contextMenu(forSelectionType: String.self) { paths in
        EntryMenu(model: model, entries: paths.compactMap(model.entry))
      } primaryAction: { paths in
        if paths.count == 1, let entry = paths.first.flatMap(model.entry) {
          // A double-clicked folder opens in place; a file opens.
          if entry.kind == .directory { model.toggle(entry) } else { model.open(entry) }
        } else {
          Task { await model.preview(paths.compactMap(model.entry)) }
        }
      }
      .onKeyPress(.space) {
        guard model.renaming == nil else { return .ignored }
        // Space again closes it, as in Finder.
        if QuickLook.isShowing {
          QuickLook.hide()
          return .handled
        }
        guard !model.selection.isEmpty else { return .ignored }
        model.previewSelection()
        return .handled
      }
      .onKeyPress(.return) {
        guard model.renaming == nil, model.selection.count == 1 else { return .ignored }
        model.renaming = model.selection.first
        return .handled
      }
      .onKeyPress(keys: [.delete, .deleteForward]) { _ in
        guard model.renaming == nil, !model.selection.isEmpty else { return .ignored }
        model.requestDelete(model.selected)
        return .handled
      }
      .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
        guard model.renaming == nil, press.modifiers.isEmpty else { return .ignored }
        if press.key == .rightArrow { model.expandOrDescend() } else { model.collapseOrAscend() }
        return .handled
      }
      .onKeyPress(keys: [.upArrow, .downArrow]) { press in
        guard press.modifiers.contains(.command) else { return .ignored }
        if press.key == .upArrow {
          model.up()
        } else if model.selection.count == 1, let entry = model.selection.first.flatMap(model.entry) {
          model.open(entry)
        }
        return .handled
      }
      .onDeleteCommand { model.requestDelete(model.selected) }
      .onCopyCommand {
        model.selected.map { NSItemProvider(object: $0.path as NSString) }
      }
    #else
      .listStyle(.plain)
    #endif
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      guard !files.isEmpty, let directory = model.directory else { return false }
      Task { await model.upload(files, into: directory) }
      return true
    }
  }
}

/// One entry: its symbol and its name, or a field while it is renamed.
private struct FileRow: View {
  @Bindable var model: FilesTab
  let entry: FileEntry
  /// How deep under the root, for the tree's indent.
  var depth = 0
  @State private var draft = ""
  @FocusState private var editing: Bool

  var body: some View {
    HStack(spacing: UIStyle.Space.inline) {
      #if os(macOS)
        disclosure
      #endif
      Image(systemName: Names.symbol(for: entry.name, kind: entry.kind))
        .font(UIStyle.symbol)
        .foregroundStyle(entry.kind == .directory ? Theme.accent : Theme.subtle)
        .frame(width: 16)
      if model.renaming == entry.path {
        TextField("Name", text: $draft)
          .textFieldStyle(.plain)
          .font(UIStyle.title)
          .focused($editing)
          .onAppear {
            draft = entry.name
            editing = true
          }
          .onSubmit { Task { await model.rename(entry, to: draft) } }
          #if os(macOS)
            .onExitCommand { model.renaming = nil }
          #endif
      } else {
        Text(Names.display(entry.name))
          .font(UIStyle.title)
          .adaptiveRowText()
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if let transfer = model.transfers.item(for: entry.path) {
        ProgressView(value: transfer.fraction)
          .progressViewStyle(.circular)
          .controlSize(.mini)
      }
    }
    #if os(macOS)
      .padding(.leading, CGFloat(depth) * FileRow.indent)
      .frame(minHeight: UIStyle.rowHeight)
    #endif
    .help(detail)
    .accessibilityElement(children: .combine)
    .accessibilityValue(detail)
    .draggable(RemoteFile(model: model, entry: entry)) {
      Label(Names.display(entry.name), systemImage: Names.symbol(for: entry.name, kind: entry.kind))
    }
    .modifier(FolderDrop(model: model, entry: entry))
    #if !os(macOS)
      .contentShape(Rectangle())
      .onTapGesture {
        if model.renaming != entry.path { model.open(entry) }
      }
      .contextMenu {
        EntryMenu(model: model, entries: [entry])
      } preview: {
        EntryPreview(model: model, entry: entry)
      }
      .swipeActions(edge: .trailing) {
        Button("Delete", systemImage: "trash", role: .destructive) {
          model.requestDelete([entry])
        }
      }
    #endif
  }

  #if os(macOS)
    /// The indent, and a chevron on a folder that turns as it opens. A file
    /// gets the chevron's width, so names line up under their folder.
    @ViewBuilder private var disclosure: some View {
      if entry.kind == .directory {
        Group {
          if model.opening.contains(entry.path) {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: "chevron.right")
              .font(UIStyle.accessory)
              .foregroundStyle(Theme.subtle)
              .rotationEffect(.degrees(model.isExpanded(entry) ? 90 : 0))
          }
        }
        .frame(width: FileRow.chevron, height: UIStyle.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(entry) }
        .accessibilityLabel(model.isExpanded(entry) ? "Collapse" : "Expand")
        .accessibilityAddTraits(.isButton)
      } else {
        Color.clear.frame(width: FileRow.chevron, height: 1)
      }
    }

    static let indent: CGFloat = 12
    static let chevron: CGFloat = 12
  #endif

  /// Size and date, for the tooltip and VoiceOver: the window itself shows
  /// only the name.
  private var detail: String {
    var parts: [String] = []
    if entry.kind == .file {
      parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
    }
    if let modified = entry.modified {
      parts.append(
        Date(timeIntervalSince1970: TimeInterval(modified))
          .formatted(date: .abbreviated, time: .shortened))
    }
    return parts.joined(separator: " · ")
  }
}

/// A folder row takes files dropped on it, from this machine.
private struct FolderDrop: ViewModifier {
  let model: FilesTab
  let entry: FileEntry

  func body(content: Content) -> some View {
    if entry.kind == .directory {
      content.dropDestination(for: URL.self) { urls, _ in
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        Task { await model.upload(files, into: entry.path) }
        return true
      }
    } else {
      content
    }
  }
}

/// What can be done to the chosen entries. Words: this is a menu.
private struct EntryMenu: View {
  let model: FilesTab
  let entries: [FileEntry]

  var body: some View {
    let files = entries.filter { $0.kind == .file }
    if entries.count == 1, let entry = entries.first, entry.kind != .file {
      #if os(macOS)
        Button("Go Into", systemImage: "arrow.turn.down.right") { model.open(entry) }
      #else
        Button("Open", systemImage: "folder") { model.open(entry) }
      #endif
    }
    if !files.isEmpty {
      Button("Quick Look", systemImage: "eye") { Task { await model.preview(files) } }
      #if os(macOS)
        let openable = files.filter { !Names.isRisky($0.name) }
        if !openable.isEmpty {
          Button("Open", systemImage: "arrow.up.forward.app") { model.openExternally(openable) }
        }
        Button("Save to Downloads", systemImage: "arrow.down.circle") {
          model.saveToDownloads(files)
        }
      #endif
    }
    #if !os(macOS)
      if files.count == 1, let file = files.first {
        ShareLink(
          item: RemoteFile(model: model, entry: file),
          preview: SharePreview(Names.display(file.name)))
      }
    #endif
    Divider()
    if entries.count == 1, let entry = entries.first {
      Button("Rename", systemImage: "pencil") { model.renaming = entry.path }
    }
    Button("Copy Path", systemImage: "doc.on.doc") { copy(entries.map(\.path)) }
    Button("Insert Path", systemImage: "terminal") { model.insertPaths(entries) }
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) { model.requestDelete(entries) }
  }

  private func copy(_ paths: [String]) {
    let text = paths.joined(separator: "\n")
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }

}

/// The directories above this one, deepest first, as Finder's title menu
/// lists them; and the switches that belong to the whole listing.
private struct PathMenu: View {
  @Bindable var model: FilesTab

  var body: some View {
    if let directory = model.directory {
      ForEach(Paths.ancestors(directory).reversed().dropFirst(), id: \.self) { path in
        Button(Names.display(Paths.name(path)), systemImage: "folder") {
          Task { await model.go(to: path) }
        }
      }
    }
    Button("Home", systemImage: "house") { model.goHome() }
    Divider()
    Toggle("Hidden Files", isOn: $model.showHidden)
  }
}

#if os(macOS)
  /// The inspector's one row of controls.
  ///
  /// The directory name is the flexible middle: it gives way before the
  /// trailing cluster, so a long path shrinks the label rather than pushing
  /// Refresh / New Folder / Upload out of a 240pt column.
  private struct MacHeader: View {
    @Bindable var model: FilesTab
    @Binding var importing: Bool

    var body: some View {
      HStack(spacing: UIStyle.Space.tight) {
        icon("Back", "chevron.left", enabled: !model.history.isEmpty) { model.back() }
        icon("Enclosing Folder", "arrow.up", enabled: model.directory != nil && model.directory != "/") { model.up() }
        Menu {
          PathMenu(model: model)
        } label: {
          Text(model.directory.map(Paths.name).map(Names.display) ?? "")
            .font(UIStyle.title)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
        .help(model.directory.map(Names.display) ?? "")
        // Loading occupies the refresh slot, so directory text never jumps.
        ZStack {
          icon("Refresh", "arrow.clockwise", enabled: model.directory != nil) { model.refresh() }
            .opacity(model.loading ? 0 : 1)
            .allowsHitTesting(!model.loading)
            .accessibilityHidden(model.loading)
          if model.loading {
            ProgressView().controlSize(.mini)
          }
        }
        .frame(width: UIStyle.controlHeight, height: UIStyle.controlHeight)
        Menu {
          Button("New Folder", systemImage: "folder.badge.plus") { model.newFolder() }
          Button("Upload", systemImage: "square.and.arrow.up") { importing = true }
        } label: {
          Image(systemName: "plus")
            .font(UIStyle.symbol)
            .frame(width: UIStyle.controlHeight, height: UIStyle.controlHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.directory == nil)
        .help("Add files or folder")
        .accessibilityLabel("Add files or folder")
      }
      .padding(.horizontal, UIStyle.Space.group)
      .frame(height: UIStyle.controlHeight + UIStyle.Space.group)
      .frame(maxWidth: .infinity)
      .background(Theme.sidebar)
    }

    private func icon(
      _ name: String, _ symbol: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
      Button(name, systemImage: symbol, action: action)
        .labelStyle(.iconOnly)
        .font(UIStyle.symbol)
        .frame(width: UIStyle.controlHeight, height: UIStyle.controlHeight)
        .buttonStyle(ChromeButtonStyle())
        .disabled(!enabled)
        .help(name)
        .layoutPriority(1)
    }
  }
#else
  /// The sheet's controls: where to go, and what to add.
  private struct PhoneToolbar: ToolbarContent {
    @Bindable var model: FilesTab
    @Binding var importing: Bool
    @State private var photos: [PhotosPickerItem] = []

    var body: some ToolbarContent {
      ToolbarItemGroup(placement: .topBarLeading) {
        Button("Enclosing Folder", systemImage: "arrow.up") { model.up() }
          .labelStyle(.iconOnly)
          .disabled(model.directory == nil || model.directory == "/")
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu("Add", systemImage: "plus") {
          Button("New Folder", systemImage: "folder.badge.plus") { model.newFolder() }
          Button("Upload from Files", systemImage: "folder") { importing = true }
          PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
            Label("Upload from Photos", systemImage: "photo")
          }
        }
        .labelStyle(.iconOnly)
        .disabled(model.directory == nil)
        .onChange(of: photos) { _, chosen in
          guard !chosen.isEmpty, let directory = model.directory else { return }
          photos = []
          Task { await upload(chosen, into: directory) }
        }
      }
    }

    /// Photos are handed over as copies in this app's temporary directory,
    /// with the names the library gives them.
    private func upload(_ items: [PhotosPickerItem], into directory: String) async {
      var files: [URL] = []
      for item in items {
        if let picked = try? await item.loadTransferable(type: PickedFile.self) {
          files.append(picked.url)
        }
      }
      await model.upload(files, into: directory)
      files.forEach { try? FileManager.default.removeItem(at: $0) }
    }
  }

  /// A thumbnail for the long-press preview: the file itself when a copy is
  /// already here, its symbol otherwise. Nothing is fetched just to be
  /// peeked at.
  private struct EntryPreview: View {
    let model: FilesTab
    let entry: FileEntry

    var body: some View {
      FilePreview(
        name: entry.name,
        kind: entry.kind,
        url: entry.kind == .file ? model.cache.cached(entry) : nil,
        side: 240
      )
      .frame(minWidth: 200, minHeight: 200)
    }
  }

  /// A file handed over by the photo picker, moved somewhere it will last
  /// until the upload has read it.
  private struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
      FileRepresentation(importedContentType: .item) { received in
        let folder = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(received.file.lastPathComponent)
        try FileManager.default.copyItem(at: received.file, to: target)
        return PickedFile(url: target)
      }
    }
  }
#endif

/// Copies in flight, and the ones that failed: a row each, under the list.
private struct TransferList: View {
  let transfers: Transfers

  var body: some View {
    if !transfers.items.isEmpty {
      VStack(spacing: 0) {
        Divider()
        ForEach(transfers.items) { item in
          HStack(spacing: UIStyle.Space.inline) {
            Image(
              systemName: item.failure != nil
                ? "exclamationmark.triangle"
                : item.direction == .down ? "arrow.down" : "arrow.up"
            )
            .font(UIStyle.symbol)
            .foregroundStyle(item.failure != nil ? Theme.warning : Theme.subtle)
            Text(item.name).font(UIStyle.detail).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: UIStyle.Space.small)
            if item.failure == nil {
              ProgressView(value: item.fraction).frame(width: 60).controlSize(.mini)
            }
            Button(item.failure != nil ? "Dismiss" : "Stop", systemImage: "xmark") {
              transfers.cancel(item.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(ChromeButtonStyle())
            .help(item.failure != nil ? "Dismiss" : "Stop")
          }
          .help(item.failure ?? item.name)
          .padding(.horizontal, UIStyle.Space.group)
          .frame(height: UIStyle.rowHeight)
        }
      }
      .background(Theme.window)
    }
  }
}

/// The questions the browser asks: a title and a verb (law: app-ui-chrome).
private struct Confirmations: ViewModifier {
  @Bindable var model: FilesTab

  func body(content: Content) -> some View {
    content
      .alert(
        alertTitle,
        isPresented: Binding(
          get: { hasAlert },
          set: { if !$0 { dismissCurrentAlert() } })
      ) {
        if !model.pendingDeletion.isEmpty {
          Button("Delete", role: .destructive) {
            // The alert binding clears pendingDeletion as the alert closes.
            // Capture the choice before SwiftUI runs that dismissal update.
            let chosen = model.pendingDeletion
            Task { await model.confirmDelete(chosen) }
          }
          Button("Cancel", role: .cancel) { model.pendingDeletion = [] }
        } else if let conflict = model.conflicts.first {
          Button("Replace", role: .destructive) {
            Task { await model.resolve(conflict, .replace) }
          }
          Button("Keep Both") { Task { await model.resolve(conflict, .keepBoth) } }
          Button("Skip", role: .cancel) { Task { await model.resolve(conflict, .skip) } }
        } else if let large = model.pendingLarge {
          Button("Download") {
            model.pendingLarge = nil
            Task { await model.preview([large], confirmed: true) }
          }
          Button("Cancel", role: .cancel) { model.pendingLarge = nil }
        }
      }
  }

  private var hasAlert: Bool {
    !model.pendingDeletion.isEmpty || !model.conflicts.isEmpty || model.pendingLarge != nil
  }

  private var alertTitle: String {
    if !model.pendingDeletion.isEmpty { return deletionTitle }
    if !model.conflicts.isEmpty { return conflictTitle }
    return largeTitle
  }

  private func dismissCurrentAlert() {
    if !model.pendingDeletion.isEmpty {
      model.pendingDeletion = []
    } else if let conflict = model.conflicts.first {
      Task { await model.resolve(conflict, .skip) }
    } else if model.pendingLarge != nil {
      model.pendingLarge = nil
    }
  }

  private var deletionTitle: String {
    let doomed = model.pendingDeletion
    if doomed.count == 1, let only = doomed.first {
      return "Delete “\(Names.display(only.name))”?"
    }
    return "Delete \(doomed.count) items?"
  }

  private var conflictTitle: String {
    guard let conflict = model.conflicts.first else { return "" }
    return "Replace “\(Names.display(conflict.name))”?"
  }

  private var largeTitle: String {
    guard let large = model.pendingLarge else { return "" }
    let size = ByteCountFormatter.string(fromByteCount: Int64(large.size), countStyle: .file)
    return "Download \(size)?"
  }
}

/// A remote file as something that can be dragged out or shared. The bytes
/// are fetched only when the other side asks for them.
struct RemoteFile: Transferable {
  let model: FilesTab
  let entry: FileEntry

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .data) { item in
      SentTransferredFile(try await item.model.local(item.entry), allowAccessingOriginalFile: false)
    }
    .suggestedFileName { Names.local($0.entry.name) }
  }
}
