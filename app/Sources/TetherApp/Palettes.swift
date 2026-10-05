import SwiftUI
import TetherUI

struct CommandItem: Identifiable {
  let id: String
  let title: String
  let detail: String
  let enabled: Bool
  let run: () -> Void
}

struct PaletteOverlay: View {
  @Bindable var tabs: TabSet
  let store: HostStore
  let commands: [CommandItem]
  let onPickHost: (Host) -> Void

  var body: some View {
    if let palette = tabs.palette {
      ZStack {
        Color.black.opacity(UIStyle.scrimOpacity)
          .ignoresSafeArea()
          .onTapGesture { tabs.palette = nil }
        GeometryReader { geometry in
          PalettePanel(
            kind: palette,
            query: $tabs.paletteQuery,
            items: items(for: palette),
            listHeight: min(UIStyle.listHeight, geometry.size.height * 0.6),
            onCancel: { tabs.palette = nil }
          )
          .frame(maxWidth: UIStyle.panelWidth)
          .padding(UIStyle.Space.inset)
          .frame(width: geometry.size.width, height: geometry.size.height)
        }
      }
    }
  }

  private func items(for palette: Palette) -> [CommandItem] {
    let query = tabs.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch palette {
    case .command:
      return commands.filter { query.isEmpty || $0.title.lowercased().contains(query) }
    case .quickSwitch:
      return quickItems.filter {
        query.isEmpty
          || $0.title.lowercased().contains(query)
          || $0.detail.lowercased().contains(query)
      }
    }
  }

  private var quickItems: [CommandItem] {
    var items: [CommandItem] = []
    if tabs.paletteQuery.isEmpty {
      items += tabs.recentHosts(in: store.listed).prefix(5).map { hostItem($0, recent: true) }
    }
    items += store.listed.map { hostItem($0, recent: false) }
    items += tabs.visibleTabs.map { tab in
      let host = tab.host.label.isEmpty ? tab.host.hostname : tab.host.label
      return CommandItem(
        id: "tab-\(tab.id)",
        title: tab.title,
        detail: tab.subtitle.isEmpty ? host : "\(host) · \(tab.subtitle)",
        enabled: true
      ) {
        tabs.select(tab.id)
        tabs.palette = nil
      }
    }
    items += tabs.visibleExtensions.map { entry in
      CommandItem(
        id: "ext-\(entry.id)",
        title: entry.workspace.title,
        detail: entry.workspace.subtitle,
        enabled: true
      ) {
        tabs.select(entry.id)
        tabs.palette = nil
      }
    }
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
  }

  private func hostItem(_ host: Host, recent: Bool) -> CommandItem {
    CommandItem(
      id: "host-\(host.id)",
      title: host.label.isEmpty ? host.hostname : host.label,
      detail: recent ? "Recent host · \(host.address)" : "Host · \(host.address)",
      enabled: true
    ) {
      tabs.palette = nil
      if tabs.tabs.contains(where: { $0.host.id == host.id })
        || tabs.extensions.contains(where: { $0.hostID == host.id }) {
        tabs.show(host)
      } else {
        onPickHost(host)
      }
    }
  }
}

struct PalettePanel: View {
  let kind: Palette
  @Binding var query: String
  let items: [CommandItem]
  let listHeight: CGFloat
  let onCancel: () -> Void
  @State private var selection = PickerSelection<String>()
  @FocusState private var focused: Bool

  private var available: [String] { items.filter(\.enabled).map(\.id) }

  var body: some View {
    VStack(spacing: 0) {
      TextField(kind == .command ? "Run a command" : "Go to host, tab, or plugin", text: $query)
        .textFieldStyle(.plain)
        .font(UIStyle.input)
        .padding(UIStyle.Space.inset)
        .focused($focused)
        .onSubmit(activateSelection)
        #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.go)
        #endif
      Divider()
      if items.isEmpty {
        Text("No matches")
          .font(UIStyle.title)
          .foregroundStyle(Theme.subtle)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(UIStyle.Space.inset)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(items) { item in
                Button {
                  if item.enabled { item.run() }
                } label: {
                  HStack {
                    VStack(alignment: .leading, spacing: UIStyle.Space.tight) {
                      Text(item.title)
                        .font(UIStyle.title)
                        .foregroundStyle(item.enabled ? Theme.text : Theme.subtle)
                      Text(item.detail)
                        .font(UIStyle.detail)
                        .foregroundStyle(Theme.subtle)
                    }
                    Spacer()
                    PickerShortcutHint(index: available.firstIndex(of: item.id))
                  }
                  .padding(.horizontal, UIStyle.Space.inset)
                  .padding(.vertical, UIStyle.Space.group)
                  .frame(minHeight: UIStyle.rowHeight)
                  .contentShape(Rectangle())
                }
                .buttonStyle(ChromeButtonStyle(selected: item.id == selection.id))
                .accessibilityAddTraits(item.id == selection.id ? .isSelected : [])
                .disabled(!item.enabled)
                .id(item.id)
              }
            }
          }
          .onChange(of: selection.id) { _, value in
            if let value { proxy.scrollTo(value, anchor: .center) }
          }
        }
        .frame(maxHeight: listHeight)
      }
    }
    .frame(maxWidth: .infinity)
    .floatingPanel()
    .accessibilityAction(.escape, onCancel)
    .task(id: kind) {
      // Request focus after the overlay has entered the responder hierarchy.
      await Task.yield()
      guard !Task.isCancelled else { return }
      focused = true
    }
    .onChange(of: available, initial: true) { _, ids in selection.reconcile(ids) }
    .onPickerCancel(onCancel)
    .onPickerNavigation { movement in
      selection.navigate(movement, pageSize: max(1, Int(listHeight / 44)), in: available)
    }
    .onPickerQuickSelection(count: available.count) { index in
      selection = PickerSelection(id: available[index])
      activateSelection()
    }
  }

  private func activateSelection() {
    if let item = items.first(where: { $0.id == selection.id && $0.enabled }) {
      item.run()
    }
  }
}
