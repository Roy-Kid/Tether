import SwiftUI

/// The host list, and nothing else.
///
/// Extensions used to sit under the hosts here. They were plumbing shown next
/// to the thing a person actually came to pick, and an enabled extension
/// already contributes its own buttons where the work is — so the section is
/// gone rather than tidied.
struct Sidebar: View {
  @Bindable var store: HostStore
  let onOpen: (Host) -> Void
  let onEdit: (Host) -> Void
  let onNew: () -> Void
  /// Only used where there is no preferences window to link to.
  let onSettings: () -> Void

  @State private var selection: Host.ID?

  var body: some View {
    List(selection: $selection) {
      Section("Hosts") {
        ForEach(store.filtered) { host in
          Button {
            selection = host.id
            onOpen(host)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "server.rack")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.tile(for: host.label))
                .frame(width: 30, height: 34)
              VStack(alignment: .leading, spacing: 3) {
                Text(host.label.isEmpty ? host.hostname : host.label).font(.body.weight(.medium))
                  .foregroundStyle(.primary)
                Text(host.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer(minLength: 0)
            }.padding(.vertical, 4).contentShape(Rectangle())
          }.buttonStyle(.plain).tag(host.id)
            .contextMenu {
              Button("Connect") { onOpen(host) }
              Button("Edit…") { onEdit(host) }
              Button("Delete host", role: .destructive) { store.delete(host) }
            }
        }
        if store.filtered.isEmpty {
          Text(store.hosts.isEmpty ? "Add a host to get started." : "No matching hosts.")
            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
        }
      }
    }
    .listStyle(.sidebar)
    // `.sidebar` is a Mac placement. On a phone the split view has collapsed
    // to a navigation stack, and asking for a sidebar slot puts the field
    // below the bottom bar — two stacked bars, with search under the buttons.
    #if os(macOS)
      .searchable(text: $store.search, placement: .sidebar, prompt: "Search hosts")
    #else
      .searchable(text: $store.search, prompt: "Search hosts")
    #endif
    .modifier(SidebarActions(onNew: onNew, onSettings: onSettings))
    .navigationTitle("Tether")
  }
}

/// Where the two standing actions live.
///
/// A Mac puts them in a bar under the sidebar, where they sit beside the list
/// for the life of the window. A phone already has a navigation bar and a
/// toolbar for exactly this, and adding a third bar underneath would be a
/// second answer to a question the platform has already answered.
private struct SidebarActions: ViewModifier {
  let onNew: () -> Void
  let onSettings: () -> Void

  func body(content: Content) -> some View {
    #if os(macOS)
      content.safeAreaInset(edge: .bottom) {
        HStack {
          // Icon-only, with the words in the tooltip: these two sit in the
          // window for the whole of its life, and a label that is read once
          // costs space on every frame after that.
          Button("Add host", systemImage: "plus", action: onNew)
            .labelStyle(.iconOnly)
            .help("Add host")

          Spacer()

          // The system's own link, so ⌘, and this button open the same
          // window rather than two copies of it.
          SettingsLink {
            Image(systemName: "gearshape")
          }
          .help("Settings")
        }
        .buttonStyle(.borderless)
        .padding(14)
        .background(.bar)
      }
    #else
      content.toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Settings", systemImage: "gearshape", action: onSettings)
            .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add host", systemImage: "plus", action: onNew)
            .labelStyle(.iconOnly)
        }
      }
    #endif
  }
}
