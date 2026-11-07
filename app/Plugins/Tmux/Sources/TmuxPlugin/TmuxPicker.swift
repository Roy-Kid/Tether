import SwiftUI
#if os(macOS)
  import AppKit
#endif
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
  @State private var keyboardSelection: String?
  @State private var draft = ""
  @FocusState private var keyboardFocused: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    layout
      .onChange(of: model.renaming) { _, renaming in
        if let renaming { draft = renaming.name }
      }
      .task(id: model.tab.id) { model.refresh() }
      .onChange(of: model.tab.id) { _, _ in opened = nil }
      #if os(macOS)
        // The list owns the keyboard until a name is being typed. While it
        // does, its shortcuts consume the keys and the field never sees them.
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .task { await Task.yield(); if !editingName { keyboardFocused = true } }
        .onChange(of: editingName) { _, editing in keyboardFocused = !editing }
        .onChange(of: keyboardItems.map(\.id), initial: true) { _, ids in
          if !ids.contains(keyboardSelection ?? "") { keyboardSelection = ids.first }
        }
        .onPickerNavigation(enabled: !editingName) { movement in
          let ids = keyboardItems.map(\.id)
          guard !ids.isEmpty else { return }
          if movement == .first { keyboardSelection = ids.first }
          else if movement == .last { keyboardSelection = ids.last }
          else {
            let index = ids.firstIndex(of: keyboardSelection ?? "") ?? 0
            let offset = movement.offset(pageSize: max(1, Int(UIStyle.listHeight / UIStyle.rowHeight)))
            keyboardSelection = ids[min(ids.count - 1, max(0, index + offset))]
          }
        }
        .onPickerSubmit(enabled: { !editingName }) {
          keyboardItems.first { $0.id == keyboardSelection }?.run()
        }
        .onPickerQuickSelection(count: editingName ? 0 : keyboardItems.count) { index in
          let items = keyboardItems
          guard items.indices.contains(index) else { return }
          let item = items[index]
          keyboardSelection = item.id
          item.run()
        }
        .onPickerCancel {
          if model.suppressPickerDismiss {
            model.suppressPickerDismiss = false
            return
          }
          if editingName { cancelEditing() }
          else if opened != nil { opened = nil }
          else { model.tab.dismissAccessory() }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, "b", "f", "B", "F"]) { press in
          guard !editingName else { return .ignored }
          let arrow = press.key == .leftArrow || press.key == .rightArrow
          let flags = press.modifiers.intersection([.control, .option, .command, .shift])
          guard arrow ? flags.isEmpty : flags == .control else { return .ignored }
          if press.key == .leftArrow || press.key.character.lowercased() == "b" {
            guard opened != nil else { return .ignored }
            opened = nil
          } else {
            guard !model.busy, let session = model.listedSessions.first(where: { "session:\($0.id)" == keyboardSelection }),
              model.windows(for: session).count > 1 else { return .ignored }
            opened = session.id
          }
          return .handled
        }
      #endif
      // The list is in one window — the summoned one or the main one, whichever
      // is showing it. The question is a sheet on that window.
      .dialog(for: model.sessionToEnd) { session in
        .confirm(
          "End this session?", verb: "End", role: .destructive,
          cancel: { model.sessionToEnd = nil },
          perform: {
            model.sessionToEnd = nil
            if opened == session.id { opened = nil }
            model.endSession(session)
          })
      }
      .dialog(for: model.windowToEnd) { window in
        .confirm(
          "End this window?", verb: "End", role: .destructive,
          cancel: { model.windowToEnd = nil },
          perform: {
            model.windowToEnd = nil
            model.endWindow(window)
          })
      }
  }

  /// Fills the inspector column on a Mac. A phone gets the sheet it is in.
  @ViewBuilder
  private var layout: some View {
    #if os(macOS)
      ScrollViewReader { proxy in
        ScrollView {
          level.padding(UIStyle.Space.group)
        }
        .onChange(of: keyboardSelection) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    #else
      ScrollView {
        level.padding(UIStyle.Space.inset)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  @ViewBuilder
  private var level: some View {
    if let opened, let session = model.listedSessions.first(where: { $0.id == opened }) {
      windows(of: session)
    } else {
      root
    }
  }

  private var root: some View {
    VStack(alignment: .leading, spacing: UIStyle.Space.tight) {
      header(model.tab.plugin.hostLabel, add: HeaderAdd(name: "New shell", id: "new-shell") {
        model.tab.newShell()
        model.tab.dismissAccessory()
      })

      let shells = model.tab.shells()
      if shells.isEmpty {
        row(
          id: "shell",
          title: model.tab.plugin.shellLabel,
          selected: model.shellSessionID == nil
        ) {
          model.showShell()
        }
      } else {
        ForEach(shells) { shell in
          row(
            id: "shell:\(shell.id)", title: shell.title,
            selected: shell.current && model.shellSessionID == nil,
            editing: editingShell(shell.id)
          ) {
            activate(shell)
          }
          .contextMenu {
            Button("Rename") { beginRename(.shell(shell.id, shell.title)) }
          }
        }
      }

      Divider()

      header("tmux sessions", add: HeaderAdd(name: "New session", id: "new-session", action: createSession))

      if model.missing {
        note("tmux isn’t installed")
      } else if let error = model.error {
        note(error).textSelection(.enabled)
      }

      if model.busy && model.listedSessions.isEmpty {
        ProgressView().controlSize(.mini).padding(.horizontal, UIStyle.Space.inline)
      }

      // One column for the dots once any session has one, so names stay in line.
      let dotted = model.listedSessions.contains { model.indicator(for: $0) != nil }
      ForEach(model.listedSessions, id: \.id) { session in
        sessionRow(session, dotted: dotted).disabled(model.busy)
      }

      if model.namingSession {
        row(id: "naming-session", title: draft, selected: false, editing: true) {}
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
          Text(session.name.isEmpty ? session.id : session.name)
            .font(UIStyle.header)
            .foregroundStyle(Theme.subtle)
          Spacer(minLength: 0)
          PickerShortcutHint(index: keyboardItems.firstIndex { $0.id == "back" })
        }
        .padding(.horizontal, UIStyle.Space.inline)
        .padding(.vertical, UIStyle.rowPadding)
        .frame(minHeight: UIStyle.rowHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(ChromeButtonStyle(selected: keyboardSelection == "back"))
      .id("back")

      Divider()

      ForEach(listed, id: \.id) { window in
        row(
          id: "window:\(window.id)",
          title: tmuxWindowLine(window),
          selected: window.active && model.shellSessionID == session.id,
          editing: editingWindow(window.id),
          // The last window is the session; that one ends from the level above.
          end: listed.count > 1 ? RowEnd("End window") { model.windowToEnd = window } : nil
        ) {
          model.choose(session, windowID: window.id)
        }
        .disabled(model.busy)
        .contextMenu {
          Button("Rename") { beginRename(.window(window)) }
          if listed.count > 1 {
            Button("End window…", role: .destructive) { model.windowToEnd = window }
          }
        }
      }

      if model.shellSessionID == session.id {
        row(id: "new-window", title: "New window", selected: false) {
          model.newWindow()
        }
        .disabled(model.busy)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sessionRow(_ session: TmuxSessionInfo, dotted: Bool) -> some View {
    let owned = model.shellSessionID == session.id
    let listed = model.windows(for: session)
    // A chevron is a promise that there is another level behind it. One
    // window is not another level: that row attaches, which is what the
    // click was for.
    let deeper = listed.count > 1
    return row(
      id: "session:\(session.id)",
      title: tmuxSessionLine(session, windows: listed, owned: owned),
      selected: owned,
      editing: editingSession(session.id),
      chevron: deeper,
      end: RowEnd("End session") { model.sessionToEnd = session },
      dot: dotted ? .some(model.indicator(for: session)) : nil
    ) {
      // The row switches. Right arrow still opens the windows.
      let window = listed.first { $0.active }?.id ?? listed.first?.id
      model.choose(session, windowID: window)
    }
    .contextMenu {
      Button("Rename") { beginRename(.session(session)) }
      if owned {
        Button("Detach session") {
          model.detachSession()
          model.tab.dismissAccessory()
        }
      }
      Button("End session…", role: .destructive) { model.sessionToEnd = session }
    }
  }

  /// The section name, and the add mark at the trailing edge. The mark is
  /// the plus alone: its name is the tooltip.
  private func header(_ text: String, add: HeaderAdd? = nil) -> some View {
    HStack(spacing: UIStyle.Space.tight) {
      Text(text)
        .font(UIStyle.header)
        .foregroundStyle(Theme.subtle)
        .lineLimit(1)
      Spacer(minLength: UIStyle.Space.tight)
      if let add {
        HeaderPlus(name: add.name, highlighted: keyboardSelection == add.id) {
          keyboardSelection = add.id
          add.action()
        }
        .disabled(model.busy)
        .id(add.id)
      }
    }
    .padding(.horizontal, UIStyle.Space.inline)
    .frame(maxWidth: .infinity, alignment: .leading)
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
    let title = session.name.isEmpty ? session.id : session.name
    var line = "\(title): \(windows.count) windows"
    if owned || session.attached { line += " (attached)" }
    return line
  }

  /// tmux `list-windows`: `1: claude* (1 panes)`
  private func tmuxWindowLine(_ window: TmuxListedWindow) -> String {
    "\(window.index): \(window.name)\(window.active ? "*" : "") (\(window.panes) panes)"
  }

  private func editingSession(_ id: String) -> Bool {
    if case .session(let session) = model.renaming { return session.id == id }
    return false
  }

  private func editingWindow(_ id: UInt32) -> Bool {
    if case .window(let window) = model.renaming { return window.id == id }
    return false
  }

  private func editingShell(_ id: UUID) -> Bool {
    if case .shell(let shell, _) = model.renaming { return shell == id }
    return false
  }

  private var editingName: Bool { model.renaming != nil || model.namingSession }

  private func beginRename(_ target: TmuxRename) {
    draft = target.name
    keyboardFocused = false
    model.renaming = target
  }

  private func cancelEditing() {
    model.suppressPickerDismiss = true
    model.renaming = nil
    model.namingSession = false
    Task { @MainActor in model.suppressPickerDismiss = false }
  }

  private func commitRename() {
    if model.namingSession {
      // Return commits. An empty field is tmux's number. Clicking away from
      // a blank field is the cancel, and does not come through here.
      model.draftName = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      model.create { [model] in
        guard model.namingSession else { return }
        model.namingSession = false
        model.tab.dismissAccessory()
      }
      return
    }
    guard let renaming = model.renaming else { return }
    model.renaming = nil
    model.rename(renaming, to: draft)
  }

  private func row(
    id: String, title: String, selected: Bool, editing: Bool = false, chevron: Bool = false,
    end: RowEnd? = nil, dot: PluginTabIndicator?? = nil, action: @escaping () -> Void
  ) -> some View {
    TreeRow(
      title: title, selected: selected, highlighted: keyboardSelection == id,
      editing: editing, draft: $draft, onCommit: commitRename, onCancel: cancelEditing,
      chevron: chevron, end: end, dot: dot, shortcutIndex: keyboardItems.firstIndex { $0.id == id }
    ) {
        keyboardSelection = id
        action()
      }
      .disabled(model.busy && !editing)
      .id(id)
  }

  private struct KeyboardItem {
    let id: String
    let run: () -> Void
  }

  private var keyboardItems: [KeyboardItem] {
    if let opened, let session = model.listedSessions.first(where: { $0.id == opened }) {
      var items = [KeyboardItem(id: "back") { self.opened = nil }]
      guard !model.busy else { return items }
      items += model.windows(for: session).map { window in
        KeyboardItem(id: "window:\(window.id)") { model.choose(session, windowID: window.id) }
      }
      if model.shellSessionID == session.id {
        items.append(KeyboardItem(id: "new-window") { model.newWindow() })
      }
      return items
    }
    guard !model.busy else { return [] }
    let shells = model.tab.shells()
    var items: [KeyboardItem] = []
    if shells.isEmpty {
      items.append(KeyboardItem(id: "shell", run: model.showShell))
    } else {
      items += shells.map { shell in
        KeyboardItem(id: "shell:\(shell.id)") { self.activate(shell) }
      }
    }
    items.append(KeyboardItem(id: "new-shell") { model.tab.newShell(); model.tab.dismissAccessory() })
    items += model.listedSessions.map { session in
      KeyboardItem(id: "session:\(session.id)") {
        let windows = model.windows(for: session)
        // A number opens the windows when there is more than one, the same
        // level the right arrow opens. One window is the session itself.
        if windows.count > 1 { self.opened = session.id }
        else { model.choose(session, windowID: windows.first?.id) }
      }
    }
    items.append(KeyboardItem(id: "new-session", run: createSession))
    return items
  }

  /// A shell on this host. This terminal, while it is inside tmux, goes back
  /// to its own shell. Any other shell is that tab, whether or not it has
  /// entered tmux.
  private func activate(_ shell: ShellChoice) {
    if shell.id == model.tab.id {
      if model.shellSessionID != nil { model.showShell() }
      else { model.tab.dismissAccessory() }
    } else {
      model.tab.openShell(shell.id)
      model.tab.dismissAccessory()
    }
  }

  private func createSession() {
    guard !model.namingSession else { return }
    draft = ""
    keyboardFocused = false
    model.namingSession = true
    keyboardSelection = "naming-session"
  }
}

#if os(macOS)
  /// Makes the name field beside it first responder, in its own window, and
  /// selects the suggested name. One claim: a later keystroke must not be
  /// selected over.
  private struct NameFieldClaim: NSViewRepresentable {
    var onClaim: () -> Void

    func makeNSView(context: Context) -> Claim { Claim() }
    func updateNSView(_ view: Claim, context: Context) {
      view.onClaim = onClaim
      view.schedule()
    }

    final class Claim: NSView {
      var onClaim: () -> Void = {}
      private var taken = false
      private var pending = false

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func schedule() {
        guard !taken, !pending else { return }
        pending = true
        attempt(remaining: 8)
      }

      private func attempt(remaining: Int) {
        Task { @MainActor [weak self] in
          guard let self else { return }
          if self.take() {
            self.taken = true
            self.pending = false
            self.onClaim()
            return
          }
          if remaining > 0 {
            self.attempt(remaining: remaining - 1)
          } else {
            self.pending = false
          }
        }
      }

      /// The field in this row. Farther up the window there are other fields.
      private func take() -> Bool {
        guard let field = nearestField(), let window = field.window else { return false }
        field.selectText(nil)
        let editor = field.currentEditor()
        return window.firstResponder === field || (editor != nil && window.firstResponder === editor)
      }

      private func nearestField() -> NSTextField? {
        var node: NSView? = superview
        var depth = 0
        while let current = node, depth < 8 {
          if let field = firstField(in: current) { return field }
          node = current.superview
          depth += 1
        }
        return nil
      }

      private func firstField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
          if let field = firstField(in: child) { return field }
        }
        return nil
      }
    }
  }
#endif

/// A header's add action. The plus carries the name; the row does not.
private struct HeaderAdd {
  let name: String
  let id: String
  let action: () -> Void
}

/// A plus at the trailing edge of a header: no border, no title.
private struct HeaderPlus: View {
  let name: String
  let highlighted: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(UIStyle.accessory)
        .foregroundStyle(hovering || highlighted ? Theme.text : Theme.subtle)
        .frame(width: UIStyle.Mark.glyph, height: UIStyle.Mark.glyph)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(name)
    .accessibilityLabel(name)
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
  let highlighted: Bool
  var editing: Bool = false
  var draft: Binding<String> = .constant("")
  var onCommit: () -> Void = {}
  var onCancel: () -> Void = {}
  let chevron: Bool
  let end: RowEnd?
  /// The status column: nil when the list has no dots, `.some(nil)` for an
  /// empty place that keeps this name in line with its neighbours'.
  var dot: PluginTabIndicator?? = nil
  let shortcutIndex: Int?
  let action: () -> Void
  @State private var hovering = false
  @State private var escaped = false
  /// The name field has taken the keyboard. A blur before that is the list
  /// handing focus over, not the person leaving the name.
  @State private var claimed = false
  @FocusState private var focused: Bool

  private static let mark: CGFloat = 10
  private static let endSize = UIStyle.Mark.glyph

  private var showsEnd: Bool { hovering && end != nil && !editing }

  var body: some View {
    Group {
      if editing {
        nameField
      } else {
        Button(action: action) { rowLabel }
          .buttonStyle(
            ChromeButtonStyle(
              selected: selected || highlighted, hovered: hovering, hoverOpacity: UIStyle.focusOpacity)
          )
      }
    }
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

  /// The name sits where the row's title was. Return keeps it; Escape leaves it.
  private var nameField: some View {
    HStack(alignment: .center, spacing: UIStyle.Space.group) {
      Image(systemName: "checkmark")
        .font(UIStyle.accessory)
        .foregroundStyle(selected ? Theme.text : .clear)
        .frame(width: Self.mark)
      dotColumn
      TextField("Name", text: draft)
        .textFieldStyle(.plain)
        .font(UIStyle.title)
        .focused($focused)
        .onAppear {
          escaped = false
          claimed = false
          focused = true
        }
        #if os(macOS)
          // This field's own window. The list may not be NSApp.keyWindow —
          // the overlay is key without the app being active — so selecting
          // whatever is first responder there never reaches this name.
          .background { NameFieldClaim { claimed = true } }
        #endif
        .onSubmit {
          escaped = true
          onCommit()
        }
        .onChange(of: focused) { _, on in
          // Becoming the field blurs the list first. That is not the person
          // leaving the name, so it does not commit. A blank field is a
          // cancel: committing it used to create a session nobody named.
          guard claimed, !on, !escaped else { return }
          Task { @MainActor in
            guard claimed, !escaped, !focused else { return }
            if draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              onCancel()
            } else {
              onCommit()
            }
          }
        }
        #if os(macOS)
          .onExitCommand {
            escaped = true
            onCancel()
          }
        #endif
        .onKeyPress(.escape) {
          escaped = true
          onCancel()
          return .handled
        }
        #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.done)
        #endif
    }
    .padding(.horizontal, UIStyle.Space.inline)
    .padding(.vertical, UIStyle.rowPadding)
    .frame(minHeight: UIStyle.rowHeight)
    .background(Theme.text.opacity(selected || highlighted ? UIStyle.focusOpacity : 0),
      in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
  }

  @ViewBuilder
  private var dotColumn: some View {
    if let dot {
      if let dot {
        StatusDot(color: dot.color, label: dot.label)
      } else {
        Color.clear.frame(width: StatusDot.size, height: StatusDot.size)
      }
    }
  }

  private var rowLabel: some View {
    HStack(alignment: .center, spacing: UIStyle.Space.group) {
      Image(systemName: "checkmark")
        .font(UIStyle.accessory)
        .foregroundStyle(selected ? Theme.text : .clear)
        .frame(width: Self.mark)
      dotColumn
      Text(title)
        .font(UIStyle.title)
        .foregroundStyle(Theme.text)
        .adaptiveRowText()
      Spacer(minLength: 0)
      PickerShortcutHint(index: shortcutIndex)
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
