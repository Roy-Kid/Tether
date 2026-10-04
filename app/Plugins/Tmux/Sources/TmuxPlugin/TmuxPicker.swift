import SwiftUI
import Tether
import TetherPluginKit
import TetherUI

/// prefix+s-style picker, behind the tab's tmux accessory. Listing never attaches;
/// only choosing a session or a window does.
///
/// One level at a time. A session with more than one window has a chevron
/// and opens its windows in place of the list; every other row is a
/// destination. The second column this used to grow on hover was 220pt of
/// Mac beside 260pt of list — wider than the phone it was also drawn on,
/// and off the side of the window on the Mac.
struct TmuxPicker: View {
  @Bindable var model: TmuxTab
  /// The session whose windows are showing, when the picker is a level in.
  @State private var opened: String?
  @Environment(\.dynamicTypeSize) private var typeSize
  #if os(macOS)
    @State private var levelHeight = UIStyle.listHeight
  #endif

  var body: some View {
    layout
      .onAppear { model.refresh() }
      .dialog(for: model.sessionToEnd) { session in
        Dialog.confirm(
          "End this session?", verb: "End", role: .destructive, cancel: { model.sessionToEnd = nil }
        ) {
          model.sessionToEnd = nil
          if opened == session.id { opened = nil }
          model.endSession(session)
        }
      }
      .dialog(for: model.windowToEnd) { window in
        Dialog.confirm(
          "End this window?", verb: "End", role: .destructive, cancel: { model.windowToEnd = nil }
        ) {
          model.windowToEnd = nil
          model.endWindow(window)
        }
      }
      .dialog(for: model.renaming) { renaming in
        Dialog.input(
          "Rename", field: Dialog.Field("Name", initial: renaming.name), verb: "Save",
          cancel: { model.renaming = nil }
        ) { name in
          model.renaming = nil
          model.rename(renaming, to: name)
        }
      }
  }

  /// A Mac gets a popover-sized column; a phone gets the sheet it is in.
  @ViewBuilder
  private var layout: some View {
    #if os(macOS)
      ScrollView {
        level.padding(UIStyle.Space.group)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            levelHeight = $0
          }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(width: UIStyle.treeWidth, alignment: .leading)
      .frame(height: min(levelHeight, UIStyle.listHeight))
    #else
      NavigationStack {
        ScrollView {
          level.padding(UIStyle.Space.inset)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button {
              model.tab.dismissAccessory()
            } label: {
              Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.iconOnly)
            .help("Close")
            .keyboardShortcut(.cancelAction)
          }
        }
      }
      .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
      .presentationDragIndicator(.visible)
    #endif
  }

  @ViewBuilder
  private var level: some View {
    if let opened, let session = model.sessions.first(where: { $0.id == opened }) {
      windows(of: session)
    } else {
      root
    }
  }

  private var root: some View {
    VStack(alignment: .leading, spacing: UIStyle.Space.tight) {
      header(model.tab.plugin.hostLabel)

      let shells = model.tab.shells()
      if shells.count > 1 {
        ForEach(shells) { shell in
          row(title: shell.title, selected: shell.current && model.shellSessionID == nil) {
            model.tab.openShell(shell.id)
            model.tab.dismissAccessory()
          }
        }
      }

      row(
        title: model.tab.plugin.shellLabel,
        selected: model.shellSessionID == nil
      ) {
        model.showShell()
      }

      row(title: "New shell…", selected: false) {
        model.tab.newShell()
        model.tab.dismissAccessory()
      }

      Divider()

      header("tmux sessions")

      if model.missing {
        note("tmux isn’t installed")
      } else if let error = model.error {
        note(error).textSelection(.enabled)
      }

      if model.busy && model.sessions.isEmpty {
        ProgressView().controlSize(.mini).padding(.horizontal, UIStyle.Space.inline)
      }

      ForEach(model.sessions, id: \.id) { session in
        sessionRow(session).disabled(model.busy)
      }

      // Last in the list, because it is what there is to do when none of
      // the sessions above is the one that was wanted.
      row(title: "New session…", selected: false) {
        let tab = model.tab
        tab.present(
          AnyView(
            CreateTmuxSheet(
              model: model,
              onCancel: tab.dismissSheet,
              onCreate: {
                tab.dismissSheet()
                tab.dismissAccessory()
              })))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// One session's windows: the second level, in place of the first.
  private func windows(of session: TmuxSessionInfo) -> some View {
    let listed = model.windows(for: session)
    return VStack(alignment: .leading, spacing: UIStyle.Space.tight) {
      Button {
        opened = nil
      } label: {
        HStack(spacing: UIStyle.Space.inline) {
          Image(systemName: "chevron.left")
            .font(UIStyle.accessory)
            .foregroundStyle(Theme.subtle)
          Text(session.name)
            .font(UIStyle.header)
            .foregroundStyle(Theme.subtle)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, UIStyle.Space.inline)
        .padding(.vertical, UIStyle.rowPadding)
        .frame(minHeight: UIStyle.rowHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(ChromeButtonStyle())

      Divider()

      ForEach(listed, id: \.id) { window in
        row(
          title: tmuxWindowLine(window),
          selected: window.active && model.shellSessionID == session.id,
          // The last window is the session; that one ends from the level above.
          end: listed.count > 1 ? RowEnd("End window") { model.windowToEnd = window } : nil
        ) {
          model.choose(session, windowID: window.id)
        }
        .disabled(model.busy)
        .contextMenu {
          Button("Rename…") { model.renaming = .window(window) }
          if listed.count > 1 {
            Button("End window…", role: .destructive) { model.windowToEnd = window }
          }
        }
      }

      if model.shellSessionID == session.id {
        row(title: "New window", selected: false) {
          model.newWindow()
        }
        .disabled(model.busy)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sessionRow(_ session: TmuxSessionInfo) -> some View {
    let owned = model.shellSessionID == session.id
    let listed = model.windows(for: session)
    // A chevron is a promise that there is another level behind it. One
    // window is not another level: that row attaches, which is what the
    // click was for.
    let deeper = listed.count > 1
    return row(
      title: tmuxSessionLine(session, windows: listed, owned: owned),
      selected: owned,
      chevron: deeper,
      end: RowEnd("End session") { model.sessionToEnd = session }
    ) {
      if deeper {
        opened = session.id
      } else {
        model.choose(session, windowID: listed.first?.id)
      }
    }
    .contextMenu {
      Button("Rename…") { model.renaming = .session(session) }
      if owned {
        Button("Detach session") {
          model.detachSession()
          model.tab.dismissAccessory()
        }
      }
      Button("End session…", role: .destructive) { model.sessionToEnd = session }
    }
  }

  private func header(_ text: String) -> some View {
    Text(text)
      .font(UIStyle.header)
      .foregroundStyle(Theme.subtle)
      .padding(.horizontal, UIStyle.Space.inline)
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(UIStyle.title)
      .foregroundStyle(Theme.subtle)
      .padding(.horizontal, UIStyle.Space.inline)
  }

  /// tmux `list-sessions`: `name: N windows (attached)`
  private func tmuxSessionLine(
    _ session: TmuxSessionInfo, windows: [TmuxListedWindow], owned: Bool
  ) -> String {
    var line = "\(session.name): \(windows.count) windows"
    if owned || session.attached { line += " (attached)" }
    return line
  }

  /// tmux `list-windows`: `1: claude* (1 panes)`
  private func tmuxWindowLine(_ window: TmuxListedWindow) -> String {
    "\(window.index): \(window.name)\(window.active ? "*" : "") (\(window.panes) panes)"
  }

  private func row(
    title: String, selected: Bool, chevron: Bool = false, end: RowEnd? = nil,
    action: @escaping () -> Void
  ) -> some View {
    TreeRow(title: title, selected: selected, chevron: chevron, end: end, action: action)
      .disabled(model.busy)
  }
}

/// The ✕ a row shows under the pointer: its name is the tooltip.
private struct RowEnd {
  let name: String
  let action: () -> Void
  init(_ name: String, action: @escaping () -> Void) {
    self.name = name
    self.action = action
  }
}

/// One line of the picker, laid out the way tmux lists it.
///
/// The ✕ sits over the row rather than in the button's label — a button
/// inside a button is not a thing either platform promises to deliver
/// clicks to — so hover belongs to the row as a whole, and the pointer
/// moving onto the ✕ is still the row being considered.
private struct TreeRow: View {
  let title: String
  let selected: Bool
  let chevron: Bool
  let end: RowEnd?
  let action: () -> Void
  @State private var hovering = false

  private static let mark: CGFloat = 10
  private static let endSize = UIStyle.Mark.glyph

  private var showsEnd: Bool { hovering && end != nil }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: UIStyle.Space.group) {
        Image(systemName: "checkmark")
          .font(UIStyle.accessory)
          .foregroundStyle(selected ? Theme.text : .clear)
          .frame(width: Self.mark)
        Text(title)
          .font(UIStyle.title)
          .foregroundStyle(Theme.text)
          .adaptiveRowText()
        Spacer(minLength: 0)
        // Room for the ✕, only while it shows: a long title gives way to it
        // instead of running underneath.
        if showsEnd {
          Color.clear.frame(width: Self.endSize, height: UIStyle.Mark.hairline)
        }
        if chevron {
          Image(systemName: "chevron.right")
            .font(UIStyle.accessory)
            .foregroundStyle(Theme.subtle)
            .frame(width: Self.mark, alignment: .trailing)
        }
      }
      .padding(.horizontal, UIStyle.Space.inline)
      .padding(.vertical, UIStyle.rowPadding)
      .frame(minHeight: UIStyle.rowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(
      ChromeButtonStyle(
        selected: selected, hovered: hovering, hoverOpacity: UIStyle.focusOpacity)
    )
    .overlay(alignment: .trailing) {
      if showsEnd, let end {
        EndButton(end: end, size: Self.endSize)
          .padding(
            .trailing,
            UIStyle.Space.inline + (chevron ? Self.mark + UIStyle.Space.group : 0))
      }
    }
    .onHover { hovering = $0 }
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityActions {
      if let end { Button(end.name, action: end.action) }
    }
  }
}

private struct EndButton: View {
  let end: RowEnd
  let size: CGFloat
  @State private var hovering = false

  var body: some View {
    Button(action: end.action) {
      Image(systemName: "xmark")
        .font(UIStyle.accessory)
        .foregroundStyle(hovering ? Theme.text : Theme.subtle)
        .frame(width: size, height: size)
        .background {
          RoundedRectangle(cornerRadius: UIStyle.rowRadius)
            .fill(Theme.text.opacity(hovering ? UIStyle.focusOpacity : 0))
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(end.name)
    .accessibilityLabel(end.name)
  }
}

struct CreateTmuxSheet: View {
  @Bindable var model: TmuxTab
  let onCancel: () -> Void
  let onCreate: @MainActor @Sendable () -> Void
  @FocusState private var nameFocused: Bool

  private var canCreate: Bool {
    !model.busy && !model.draftName.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $model.draftName)
          .disabled(model.busy)
          .focused($nameFocused)
          .onSubmit(create)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
          #endif
        if let error = model.error {
          Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
        }
        if model.busy {
          ProgressView().frame(maxWidth: .infinity)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("New Session")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { onCancel() }
            .keyboardShortcut(.cancelAction)
            .disabled(model.busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") { create() }
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: UIStyle.menuWidth, minHeight: UIStyle.menuHeight)
    #endif
    .interactiveDismissDisabled(model.busy)
    .task {
      await Task.yield()
      guard !Task.isCancelled else { return }
      nameFocused = true
    }
  }

  private func create() {
    guard canCreate else { return }
    model.create(onSuccess: onCreate)
  }
}

/// The same menu the tab carries, beside the terminal when the inspector is open.
struct TmuxInspector: View {
  @Bindable var model: TmuxTab
  var body: some View {
    Form {
      Section {
        LabeledContent("Host", value: model.tab.plugin.hostLabel)
        LabeledContent("Session", value: model.subtitle.isEmpty ? model.tab.plugin.shellLabel : model.subtitle)
      }
      if !model.commands.isEmpty {
        Section {
          ForEach(model.commands) { command in
            Button(command.title, systemImage: command.symbol, action: command.action)
          }
        }
        .disabled(model.busy)
      }
    }
    .formStyle(.grouped)
  }
}
