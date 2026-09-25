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
      .confirmationDialog(
        "End this session?",
        isPresented: Binding(
          get: { model.sessionToEnd != nil },
          set: { if !$0 { model.sessionToEnd = nil } })
      ) {
        Button("End", role: .destructive) {
          guard let session = model.sessionToEnd else { return }
          model.sessionToEnd = nil
          if opened == session.id { opened = nil }
          model.endSession(session)
        }
      }
      .confirmationDialog(
        "End this window?",
        isPresented: Binding(
          get: { model.windowToEnd != nil },
          set: { if !$0 { model.windowToEnd = nil } })
      ) {
        Button("End", role: .destructive) {
          guard let window = model.windowToEnd else { return }
          model.windowToEnd = nil
          model.endWindow(window)
        }
      }
      .alert(
        "Rename",
        isPresented: Binding(
          get: { model.renameWindow != nil || model.renameSession != nil },
          set: {
            if !$0 {
              model.renameWindow = nil
              model.renameSession = nil
            }
          })
      ) {
        TextField("Name", text: $model.renameText)
        Button("Cancel", role: .cancel) {
          model.renameWindow = nil
          model.renameSession = nil
        }
        Button("Save") {
          let name = model.renameText
          if let window = model.renameWindow {
            model.perform(.renameWindow(id: window.id, name: name))
          }
          if let session = model.renameSession {
            model.renameSession(session, to: name)
          }
          model.renameWindow = nil
          model.renameSession = nil
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
        .navigationTitle("tmux sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { model.tab.dismissAccessory() }
              .labelStyle(.iconOnly)
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

      row(
        title: model.tab.plugin.shellLabel,
        selected: !model.showing && model.shellSessionID == nil
      ) {
        model.showShell()
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
          selected: window.active
            && ((model.session?.id == session.id && model.showing)
              || (!model.showing && model.shellSessionID == session.id)),
          // The last window is the session; that one ends from the level above.
          end: listed.count > 1 ? RowEnd("End window") { model.windowToEnd = window } : nil
        ) {
          model.choose(session, windowID: window.id)
        }
        .disabled(model.busy)
        .contextMenu {
          Button("Rename…") {
            model.renameWindow = TmuxWindowInfo(
              id: window.id, name: window.name, active: window.active, width: 1, height: 1)
            model.renameText = window.name
          }
          if listed.count > 1 {
            Button("End window…", role: .destructive) { model.windowToEnd = window }
          }
        }
      }

      if model.session?.id == session.id {
        row(title: "New window", selected: false) {
          model.perform(.newWindow)
        }
        .disabled(model.busy || model.ended)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sessionRow(_ session: TmuxSessionInfo) -> some View {
    let owned = model.session?.id == session.id
    let listed = model.windows(for: session)
    // A chevron is a promise that there is another level behind it. One
    // window is not another level: that row attaches, which is what the
    // click was for.
    let deeper = listed.count > 1
    return row(
      title: tmuxSessionLine(session, windows: listed, owned: owned),
      selected: (owned && model.showing)
        || (!model.showing && model.shellSessionID == session.id),
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
      Button("Rename…") {
        model.renameSession = session
        model.renameText = session.name
      }
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
  private static let endSize: CGFloat = 16

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
          Color.clear.frame(width: Self.endSize, height: 1)
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
      .frame(minWidth: 340, minHeight: 180)
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
