import SwiftUI
import Tether
import TetherPluginKit
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
      .onChange(of: model.query) { previous, next in
        let cleaned = next.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        if cleaned != next {
          model.query = cleaned
          return
        }
        model.noteQueryChange(from: previous)
      }
      .onChange(of: model.finding) { _, open in
        if !open, !model.query.isEmpty { model.query = "" }
      }
      .fileImporter(
        isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true
      ) { result in
        guard case .success(let files) = result, let target = model.targetDirectory else { return }
        Task { await model.upload(files, into: target) }
      }
      .modifier(DownloadPicker(model: model))
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
          .searchable(
            text: $model.query, isPresented: $model.finding,
            placement: .navigationBarDrawer(displayMode: .automatic), prompt: ""
          )
          .onSubmit(of: .search) { model.commitFind() }
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
  @State private var listHeight = UIStyle.listHeight

  var body: some View {
    ScrollViewReader { proxy in
      listing
        .onChange(of: model.selection) { _, paths in
          if paths.count == 1, let path = paths.first { proxy.scrollTo(path) }
        }
    }
  }

  private var listing: some View {
    List(selection: $model.selection) {
      if let problem = model.problem {
        Label(problem, systemImage: "exclamationmark.triangle")
          .font(UIStyle.detail)
          .foregroundStyle(Theme.subtle)
      }
      #if os(macOS)
        // A tree, as an editor's explorer is: folders open in place.
        ForEach(model.displayedRows) { row in
          FileRow(model: model, entry: row.entry, depth: row.depth)
            .tag(row.entry.path)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        }
      #else
        // A phone drills down: one directory a screen.
        ForEach(model.displayed, id: \.path) { entry in
          FileRow(model: model, entry: entry)
            .tag(entry.path)
        }
      #endif
    }
    #if os(macOS)
      .listStyle(.inset)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
      .focused($listFocused)
      .background { ListKeyboardClaim() }
      .onAppear { listFocused = true }
      .onChange(of: model.listTicket) { _, _ in listFocused = true }
      .environment(\.defaultMinListRowHeight, UIStyle.rowHeight)
      .contextMenu(forSelectionType: String.self) { paths in
        EntryMenu(model: model, entries: paths.compactMap(model.entry))
      } primaryAction: { paths in
        if paths.count == 1, let entry = paths.first.flatMap(model.entry) {
          // A double-click opens the row. A folder becomes the root;
          // the chevron is what expands it in place.
          model.open(entry)
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
      .onPickerSubmit(enabled: model.renaming == nil && model.selection.count == 1) {
        model.renaming = model.selection.first
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
      // Control+F/B arrive as control codes, so a key of "f" never sees them.
      // A selected folder takes them, the same as the arrows. Find takes
      // Control+F when the selection is not a folder.
      .onKeyPress(phases: .down) { press in
        guard model.renaming == nil, let chord = treeChord(press) else { return .ignored }
        guard chord == .back || model.selection.first.flatMap(model.entry)?.kind == .directory
        else { return .ignored }
        if chord == .forward { model.expandOrDescend() } else { model.collapseOrAscend() }
        return .handled
      }
      .onPickerNavigation(enabled: model.renaming == nil) { movement in
        switch movement {
        case .first, .last:
          let row = movement == .first ? model.rows.first : model.rows.last
          model.selection = row.map { [$0.id] } ?? []
        default:
          let offset = movement.offset(pageSize: max(1, Int(listHeight / UIStyle.rowHeight)))
          model.moveSelection(forward: offset > 0, steps: abs(offset))
        }
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
      .onKeyPress(.escape) {
        guard model.finding else { return .ignored }
        model.closeFind()
        return .handled
      }
      // On the list, not the window: ⌃F while the terminal has the keyboard
      // is still forward-char for the shell.
      .onKeyPress(phases: .down) { press in
        guard findChord(press) else { return .ignored }
        // The folder row keeps Control+F as Right Arrow. Find is the other case.
        if model.renaming == nil, model.selection.count == 1,
          model.selection.first.flatMap(model.entry)?.kind == .directory
        {
          return .ignored
        }
        model.beginFind()
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

#if os(macOS)
  /// A click in the list selects a row and leaves the keyboard where it was,
  /// which is the terminal. This view does not take the click; it moves the
  /// first responder onto the list the click landed in.
  private struct ListKeyboardClaim: NSViewRepresentable {
    func makeNSView(context: Context) -> ListKeyboardClaimView { ListKeyboardClaimView() }
    func updateNSView(_ view: ListKeyboardClaimView, context: Context) {}
  }

  private final class ListKeyboardClaimView: NSView {
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
        [weak self] event in
        self?.takeKeyboard(event)
        return event
      }
    }

    private func takeKeyboard(_ event: NSEvent) {
      guard let window, event.window === window else { return }
      let point = convert(event.locationInWindow, from: nil)
      guard bounds.contains(point) else { return }
      let hit = window.contentView?.hitTest(event.locationInWindow)
      if hit is NSTextView { return }
      var table: NSTableView?
      var fallback: NSView?
      var view: NSView? = hit
      while let current = view {
        if let found = current as? NSTableView {
          table = found
          break
        }
        if fallback == nil, current.acceptsFirstResponder { fallback = current }
        view = current.superview
      }
      if let table {
        window.makeFirstResponder(table)
      } else if let fallback {
        window.makeFirstResponder(fallback)
      }
    }
  }
#endif

/// One entry: its symbol and its name, or a field while it is renamed.
private struct FileRow: View {
  @Bindable var model: FilesTab
  let entry: FileEntry
  /// How deep under the root, for the tree's indent.
  var depth = 0
  @State private var draft = ""
  @FocusState private var editing: Bool

  var body: some View {
    Group {
      #if os(macOS)
        GeometryReader { geometry in
          // Deep paths must give up indentation before they consume the name
          // editor. Reserve room for the name, icons and a transfer indicator.
          let indentation = min(CGFloat(depth) * FileRow.indent,
            max(0, geometry.size.width - FileRow.contentWidth))
          content
            .padding(.leading, indentation)
            .frame(maxHeight: .infinity)
        }
        .frame(height: UIStyle.rowHeight)
      #else
        content
      #endif
    }
    .help(detail)
    .accessibilityElement(children: .combine)
    .accessibilityValue(detail)
    .modifier(EntryDrag(model: model, entry: entry))
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

  private var content: some View {
    HStack(spacing: UIStyle.Space.inline) {
      #if os(macOS)
        disclosure
      #endif
      Image(systemName: Names.symbol(for: entry.name, kind: entry.kind))
        .font(UIStyle.symbol)
        .foregroundStyle(entry.kind == .directory ? Theme.accent : Theme.subtle)
        .frame(width: UIStyle.Mark.glyph)
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
            .frame(minWidth: FileRow.nameWidth, maxWidth: .infinity)
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
        Color.clear.frame(width: FileRow.chevron, height: UIStyle.Mark.hairline)
      }
    }

    static let indent: CGFloat = 12
    static let chevron = UIStyle.Mark.chevron
    static let nameWidth: CGFloat = 80
    static let contentWidth = nameWidth + chevron + UIStyle.Mark.glyph
      + UIStyle.controlHeight + 4 * UIStyle.Space.inline
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

/// Dragging a row carries the absolute path Copy Path would copy. A file
/// also offers its bytes, so a drop outside this app can still take the file.
private struct EntryDrag: ViewModifier {
  let model: FilesTab
  let entry: FileEntry

  func body(content: Content) -> some View {
    let text = model.draggedPathText(entry)
    if entry.kind == .file {
      content.draggable(DraggedFile(text: text, file: RemoteFile(model: model, entry: entry))) {
        preview
      }
    } else {
      content.draggable(DroppedPath(text: text)) { preview }
    }
  }

  private var preview: some View {
    Label(Names.display(entry.name), systemImage: Names.symbol(for: entry.name, kind: entry.kind))
  }
}

/// A file row's drag: the absolute path, and the bytes when something asks.
struct DraggedFile: Transferable {
  let text: String
  let file: RemoteFile

  static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation { DroppedPath(text: $0.text) }
    FileRepresentation(exportedContentType: .data) { item in
      SentTransferredFile(
        try await item.file.model.local(item.file.entry), allowAccessingOriginalFile: false)
    }
    .suggestedFileName { Names.local($0.file.entry.name) }
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
      #endif
      Button("Download", systemImage: "arrow.down.circle") { model.download(files) }
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
    Button("Copy Path", systemImage: "doc.on.doc") { copy(Names.copiedPaths(entries.map(\.path))) }
    Button("Insert Path", systemImage: "terminal") { model.insertPaths(entries) }
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) { model.requestDelete(entries) }
  }

  private func copy(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }

}

/// Where the browser can go from here, then the switches for the listing.
///
/// Enclosing directories come nearest first. A directory that is already in
/// that list is not repeated as Home or Shell: the account home under
/// `/home` would otherwise read as `home` and then Home.
private struct PathMenu: View {
  @Bindable var model: FilesTab

  var body: some View {
    let places = model.pathPlaces
    if !places.places.isEmpty {
      Section {
        ForEach(places.places, id: \.self) { path in
          Button {
            Task { await model.go(to: path) }
          } label: {
            Label(places.title(path), systemImage: places.symbol(path))
          }
          .help(Names.display(path))
        }
      }
    }
    if places.showsHome || places.showsShell {
      Section {
        if places.showsHome {
          Button("Home", systemImage: "house") { model.goHome() }
            .help(places.home.map(Names.display) ?? "Home")
        }
        if places.showsShell, let shell = places.shell {
          Button("Shell", systemImage: "terminal") { model.goToShell() }
            .help(Names.display(shell))
        }
      }
    }
    Section {
      Toggle(isOn: $model.showHidden) {
        Label("Hidden Files", systemImage: "eye")
      }
    }
  }
}

/// Control+B/F for the file tree. The character with Control held is the
/// control code, not the letter.
private enum TreeChord { case forward, back }

private func treeChord(_ press: KeyPress) -> TreeChord? {
  guard press.modifiers.contains(.control),
    !press.modifiers.contains(.command),
    !press.modifiers.contains(.option),
    !press.modifiers.contains(.shift)
  else { return nil }
  switch press.characters {
  case "f", "F", "\u{06}": return .forward
  case "b", "B", "\u{02}": return .back
  default: return nil
  }
}

/// ⌃F, and not ⌃⇧F or a command chord. The character with Control held is
/// the control code, not "f".
private func findChord(_ press: KeyPress) -> Bool {
  guard press.modifiers.contains(.control),
    !press.modifiers.contains(.command),
    !press.modifiers.contains(.option),
    !press.modifiers.contains(.shift)
  else { return false }
  return press.characters == "f" || press.characters == "\u{06}"
}

#if os(macOS)
  /// The inspector's one row of controls.
  ///
  /// The directory name is the flexible middle: it gives way before the
  /// trailing cluster, so a long path shrinks the label rather than pushing
  /// Refresh / New Folder / Upload out of a 240pt column. Find uses that
  /// same slot. The shell glyph sits in it too, and only when the shell is
  /// somewhere else, so the trailing cluster never gains a control.
  private struct MacHeader: View {
    @Bindable var model: FilesTab
    @Binding var importing: Bool
    @FocusState private var findFocused: Bool

    var body: some View {
      HStack(spacing: UIStyle.Space.tight) {
        icon("Back", "chevron.left", enabled: !model.history.isEmpty) { model.back() }
        icon("Enclosing Folder", "arrow.up", enabled: model.directory != nil && model.directory != "/") { model.up() }
        middle
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
      .onChange(of: model.findTicket) { _, _ in findFocused = true }
    }

    /// The name, or the field that replaces it. The shell glyph is part of
    /// this slot: it appears when the browser has left the shell, and it is
    /// gone while finding, whose own symbol says which directory a path uses.
    private var middle: some View {
      HStack(spacing: UIStyle.Space.tight) {
        if model.shellDirectory != nil, !model.finding {
          Button("Shell", systemImage: "terminal") { model.goToShell() }
            .labelStyle(.iconOnly)
            .font(UIStyle.symbol)
            .frame(width: UIStyle.controlHeight, height: UIStyle.controlHeight)
            .buttonStyle(ChromeButtonStyle())
            .fixedSize()
            .help("Shell")
            .accessibilityLabel("Shell")
        }
        if model.finding {
          findField
        } else {
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
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var findField: some View {
      HStack(spacing: UIStyle.Space.tight) {
        Image(systemName: model.findSymbol)
          .font(UIStyle.symbol)
          .foregroundStyle(Theme.subtle)
          .accessibilityHidden(true)
        TextField("", text: $model.query)
          .textFieldStyle(.plain)
          .font(UIStyle.title)
          .focused($findFocused)
          .accessibilityLabel("Find")
          .autocorrectionDisabled()
          .onSubmit { model.commitFind() }
          .onExitCommand { model.closeFind() }
          .onKeyPress(.upArrow) {
            guard model.findingByName else { return .ignored }
            model.moveMatch(by: -1)
            return .handled
          }
          .onKeyPress(.downArrow) {
            guard model.findingByName else { return .ignored }
            model.moveMatch(by: 1)
            return .handled
          }
          .onKeyPress(.escape) {
            model.closeFind()
            return .handled
          }
          .onKeyPress(phases: .down) { press in
            guard findChord(press) else { return .ignored }
            model.beginFind()
            return .handled
          }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
        icon("Back", "chevron.left") { model.back() }
          .disabled(model.history.isEmpty)
        icon("Enclosing Folder", "arrow.up") { model.up() }
          .disabled(model.directory == nil || model.directory == "/")
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        if model.shellDirectory != nil, !model.finding {
          icon("Shell", "terminal") { model.goToShell() }
        }
        if model.loading {
          ProgressView()
        } else {
          icon("Refresh", "arrow.clockwise") { model.refresh() }
            .disabled(model.directory == nil)
        }
        Menu {
          Button("New Folder", systemImage: "folder.badge.plus") { model.newFolder() }
          Button("Upload from Files", systemImage: "folder") { importing = true }
          PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
            Label("Upload from Photos", systemImage: "photo")
          }
        } label: {
          Image(systemName: "plus")
        }
        .help("Add files or folder")
        .accessibilityLabel("Add files or folder")
        .disabled(model.directory == nil)
        .onChange(of: photos) { _, chosen in
          guard !chosen.isEmpty, let directory = model.directory else { return }
          photos = []
          Task { await upload(chosen, into: directory) }
        }
      }
    }

    /// Same symbols as the Mac header. The name is the tooltip; the bar
    /// would otherwise draw it beside the icon.
    private func icon(
      _ name: String, _ symbol: String, action: @escaping () -> Void
    ) -> some View {
      Button(action: action) {
        Label(name, systemImage: symbol)
      }
      .buttonStyle(.iconOnly)
      .help(name)
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
    /// The copy that matches the file's modification time now, when one is
    /// already here. A listing from before the write is not used.
    @State private var url: URL?

    var body: some View {
      FilePreview(name: entry.name, kind: entry.kind, url: url, side: 240)
        .frame(minWidth: UIStyle.compactHeight, minHeight: UIStyle.compactHeight)
        .task {
          guard entry.kind == .file, let source = try? await model.source() else { return }
          let current = await model.identities([entry], from: source)
          guard let file = current.first else { return }
          if source.isLocal {
            url = model.localPreviewCopy(file) ?? URL(fileURLWithPath: file.path)
          } else {
            url = model.cache.cached(file)
          }
        }
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
              ProgressView(value: item.fraction).frame(width: UIStyle.Mark.progress).controlSize(.mini)
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

/// A folder for a download, asked when none has been set. The files are copied
/// out before the panel closes, so a cancel and a choice both see them.
private struct DownloadPicker: ViewModifier {
  @Bindable var model: FilesTab
  @State private var presented = false
  @State private var saving: [FileEntry] = []

  func body(content: Content) -> some View {
    content
      .onChange(of: model.pendingSave.map(\.path)) { _, paths in
        guard !paths.isEmpty else { return }
        saving = model.pendingSave
        presented = true
      }
      .background {
        Color.clear
          .fileImporter(
            isPresented: $presented, allowedContentTypes: [.folder], allowsMultipleSelection: false
          ) { result in
            let files = saving
            saving = []
            model.pendingSave = []
            guard case .success(let urls) = result, let folder = urls.first, !files.isEmpty else {
              return
            }
            Task { await model.save(files, to: folder) }
          }
          #if os(macOS)
            .fileDialogDefaultDirectory(model.preferredDownloadDirectory)
          #endif
      }
  }
}

/// The questions the browser asks: a title and a verb (law: app-ui-chrome).
///
/// One at a time, deletion first. Each answer settles its own question, and
/// the next one — another name already taken — follows as its own dialog.
private struct Confirmations: ViewModifier {
  @Bindable var model: FilesTab

  /// Which question is open, as something that changes when it does.
  private enum Question: Hashable {
    case delete([String])
    case conflict(UUID)
    case download(String)
  }

  private var question: Question? {
    if !model.pendingDeletion.isEmpty { return .delete(model.pendingDeletion.map(\.path)) }
    if let conflict = model.conflicts.first { return .conflict(conflict.id) }
    if let large = model.pendingLarge { return .download(large.path) }
    return nil
  }

  func body(content: Content) -> some View {
    content.dialog(for: question) { _ in dialog }
  }

  private var dialog: Dialog {
    if !model.pendingDeletion.isEmpty {
      let doomed = model.pendingDeletion
      return .confirm(
        deletionTitle(doomed), verb: "Delete", role: .destructive, cancel: { model.pendingDeletion = [] }
      ) {
        model.pendingDeletion = []
        Task { await model.confirmDelete(doomed) }
      }
    }
    if let conflict = model.conflicts.first {
      let settle = { (choice: Conflict.Choice) in Task { await model.resolve(conflict, choice) } }
      return Dialog(
        title: "Replace “\(Names.display(conflict.name))”?",
        actions: [
          Dialog.Action("Replace", role: .destructive) { _ in settle(.replace) },
          Dialog.Action("Keep Both") { _ in settle(.keepBoth) },
          .cancel("Skip") { settle(.skip) },
        ])
    }
    let fetch = model.pendingFetch
    let large = model.pendingLarge
    let size = ByteCountFormatter.string(fromByteCount: Int64(large?.size ?? 0), countStyle: .file)
    return .confirm(
      "Download \(size)?", verb: "Download",
      cancel: {
        model.pendingLarge = nil
        model.pendingFetch = nil
      }
    ) {
      model.pendingLarge = nil
      model.pendingFetch = nil
      switch fetch {
      case .preview(let files):
        Task { await model.preview(files, confirmed: true) }
      case .open(let files):
        Task { await model.openFetched(files, confirmed: true) }
      case nil:
        if let large { Task { await model.preview([large], confirmed: true) } }
      }
    }
  }

  private func deletionTitle(_ doomed: [FileEntry]) -> String {
    if doomed.count == 1, let only = doomed.first {
      return "Delete “\(Names.display(only.name))”?"
    }
    return "Delete \(doomed.count) items?"
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
