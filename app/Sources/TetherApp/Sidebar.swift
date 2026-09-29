import SwiftUI
import TetherUI
#if os(macOS)
  import AppKit
#endif

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
  var onDone: (() -> Void)? = nil

  @State private var selection: Host.ID?
  @State private var identityHost: Host?

  var body: some View {
    List(selection: $selection) {
      if let problem = store.problem {
        // The list is a file someone else can own the permissions of. A
        // person who adds a host and sees nothing happen has no way to guess
        // that, so it is said here rather than logged.
        Label(problem, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .padding(.vertical, UIStyle.Space.inline)
      }
      Section("Hosts") {
        ForEach(store.filtered) { host in
          Button {
            selection = host.id
            onOpen(host)
          } label: {
            HStack(spacing: UIStyle.panelRadius) {
              Image(systemName: "server.rack")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.tile(for: host.label))
                .frame(width: UIStyle.Mark.tileWidth, height: UIStyle.Mark.tileHeight)
              VStack(alignment: .leading, spacing: UIStyle.rowPadding) {
                Text(host.label.isEmpty ? host.hostname : host.label).font(.body.weight(.medium))
                  .adaptiveRowText()
                  .foregroundStyle(.primary)
                Text(host.address).font(.caption).foregroundStyle(.secondary).adaptiveRowText()
              }
              Spacer(minLength: 0)
            }.padding(.vertical, UIStyle.Space.small)
              .frame(minHeight: UIStyle.rowHeight)
              .contentShape(Rectangle())
          }.buttonStyle(.plain).tag(host.id)
            #if os(iOS)
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !host.isLocal {
                  Button("Identity…", systemImage: "person.badge.key") { identityHost = host }
                    .tint(Theme.accent)
                }
              }
            #endif
            .contextMenu {
              Button("Connect") { onOpen(host) }
              // A label, a hostname, a port and a user are four answers the
              // local machine already knows, so there is nothing an editor
              // could ask; and a person must not be able to delete their own
              // computer out of a list they are reading on it. Not a second
              // kind of host — a host with nothing left to decide.
              if !host.isLocal {
                Button("Identity and Authentication…") { identityHost = host }
                if host.isManaged {
                  Button("Edit…") { onEdit(host) }
                  Button("Delete host", role: .destructive) { store.delete(host) }
                } else {
                  Button("Add to Tether") { store.adopt(host) }
                }
              }
            }
        }
        if store.filtered.isEmpty && !store.listed.isEmpty {
          Text("No matching hosts.")
            .font(.callout).foregroundStyle(.secondary).padding(.vertical, UIStyle.Space.group)
        }
      }
    }
    .sheet(item: $identityHost) { host in
      NavigationStack { HostIdentitySettings(store: store, id: host.id) }
        .frame(minWidth: UIStyle.sheetWidth, minHeight: UIStyle.sheetHeight)
    }
    .modifier(HostListStyle())
    // This list is also used in a sheet, where `.sidebar` search placement
    // promotes the field into an unrelated window toolbar. Keep Mac search
    // inside the content; explicitly anchor phone search below the title.
    #if os(macOS)
      .safeAreaInset(edge: .top, spacing: 0) {
        HostSearchField(text: $store.search)
          .frame(height: UIStyle.controlHeight)
          .padding(UIStyle.Space.inset)
          .background(Theme.sidebar)
      }
    #else
      .searchable(text: $store.search,
                  placement: .navigationBarDrawer(displayMode: .always), prompt: "Search hosts")
      .scrollDismissesKeyboard(.interactively)
    #endif
    .overlay {
      if store.listed.isEmpty && store.problem == nil {
        ContentUnavailableView {
          Label("Hosts", systemImage: "server.rack")
        } actions: {
          Button("Add host", systemImage: "plus", action: onNew)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .modifier(SidebarActions(onNew: onNew, onSettings: onSettings, onDone: onDone))
    .navigationTitle(onDone == nil ? "Tether" : "Hosts")
  }
}

#if os(macOS)
private struct HostSearchField: NSViewRepresentable {
  @Binding var text: String

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search hosts"
    field.setAccessibilityLabel("Search hosts")
    field.sendsSearchStringImmediately = true
    field.target = context.coordinator
    field.action = #selector(Coordinator.changed(_:))
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.text = $text
    if field.stringValue != text { field.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }
    // The action arrives from the field on the main thread; reading
    // `stringValue` and writing the binding both belong there.
    @MainActor @objc func changed(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
  }
}
#endif

private struct HostListStyle: ViewModifier {
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  @ViewBuilder
  func body(content: Content) -> some View {
    #if os(macOS)
      content.listStyle(.sidebar)
    #else
      if sizeClass == .regular {
        content.listStyle(.sidebar)
      } else {
        content.listStyle(.insetGrouped)
      }
    #endif
  }
}

/// Where Add lives under the host list.
///
/// Settings is not here. On a Mac it sits on the workspace status bar,
/// opposite the host control. A phone has no preferences window and no
/// status bar, so the gear stays in the navigation bar and presents a sheet.
/// The navigation bar draws a toolbar button's title next to its icon.
/// A custom button style replaces that chrome, so only the icon remains.
private struct IconOnlyButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.labelStyle(.iconOnly)
  }
}

extension ButtonStyle where Self == IconOnlyButtonStyle {
  fileprivate static var iconOnly: Self { Self() }
}

private struct SidebarActions: ViewModifier {
  let onNew: () -> Void
  let onSettings: () -> Void
  let onDone: (() -> Void)?

  func body(content: Content) -> some View {
    #if os(macOS)
      content.safeAreaInset(edge: .bottom) {
        HStack {
          Button("Add host", systemImage: "plus", action: onNew)
            .labelStyle(.iconOnly)
            .help("Add host")
          Spacer()
          if let onDone {
            Button("Done", action: onDone)
              .buttonStyle(.borderedProminent)
              .keyboardShortcut(.cancelAction)
          }
        }
        .buttonStyle(.borderless)
        .padding(UIStyle.Space.inset)
        .background(.bar)
      }
    #else
      content.toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Settings", systemImage: "gearshape", action: onSettings)
            .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: onNew) {
            Label("Add host", systemImage: "plus")
          }
          .buttonStyle(.iconOnly)
        }
        if let onDone {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: onDone)
          }
        }
      }
    #endif
  }
}
