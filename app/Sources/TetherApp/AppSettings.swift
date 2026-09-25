import SwiftUI
import Tether
import TetherPluginKit
import TetherUI

/// Whether a window opens on a prompt or on the host list.
///
/// The key and the default live together because three places need to agree
/// about them — the toggle, the launch path, and the test that covers it —
/// and a literal repeated three times is a default that drifts.
enum LaunchPreference {
  static let key = "openLocalAtLaunch"

  /// On. A terminal application that opens on nothing is asking a person to
  /// do setup before it has been useful once, and the one machine it can
  /// always reach needs none.
  static let `default` = true
}

/// Settings, as two panes rather than a row of tabs.
///
/// A tab strip puts every section on screen at once and then hides all but
/// one of them, which stops scaling the moment a third section exists. A
/// sidebar is the same shape as the rest of the app, so the window a person
/// already knows how to read does not change its rules when they open
/// preferences.
///
/// A phone has no room for two columns and no window to size: the same
/// sections are a list that pushes its pane, which is where a phone keeps
/// settings anyway. The Mac's shape was being drawn there too — a 680pt
/// split view inside a sheet, clipped to a column of half-words.
struct AppSettings: View {
  let registry: PluginRegistry
  let known: KnownHosts
  let store: HostStore
  let secrets: any SecretStore
  var connections: TabSet? = nil

  #if os(macOS)
    /// Which pane the split view is showing. A phone pushes instead.
    @State private var section: Section? = Section.available.first
    @AppStorage("appearance") private var appearance = "system"
  #endif

  private enum Section: String, Identifiable, CaseIterable {
    case general
    case appearance
    case security
    case identities
    case extensions

    var id: String { rawValue }

    var title: String {
      switch self {
      case .general: "General"
      case .appearance: "Appearance"
      case .security: "Security"
      case .identities: "Identities"
      case .extensions: "Extensions"
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .appearance: "paintpalette"
      case .security: "lock.shield"
      case .identities: "person.badge.key"
      case .extensions: "puzzlepiece.extension"
      }
    }

    /// Sections a platform has nothing to put in are not shown empty.
    static var available: [Self] {
      allCases.filter { $0 != .general || TerminalSession.isLocalAvailable }
    }
  }

  var body: some View {
    #if os(macOS)
      HStack(spacing: 0) {
        List(Section.available, selection: $section) { section in
          Label(section.title, systemImage: section.symbol).tag(section)
        }
        .listStyle(.sidebar)
        .frame(width: 180)
        Divider()
        pane(section ?? .appearance)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      // Settings has permanent categories, not collapsible navigation. Let
      // the native titlebar own its height instead of adding safe-area shims.
      .frame(minWidth: 680, idealWidth: 720, minHeight: 460, idealHeight: 500)
      .background { StandardTitlebar() }
      .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    #else
      // The caller already supplies the stack and its Done button, so this
      // is the list and nothing around it.
      List(Section.available) { section in
        NavigationLink {
          pane(section)
        } label: {
          Label(section.title, systemImage: section.symbol)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  @ViewBuilder
  private func pane(_ section: Section) -> some View {
    Form {
      switch section {
      case .identities:
        IdentitySettings(store: store, connections: connections)
        DeviceSettings(store: store, known: known)
      case .general: GeneralSettings()
      case .appearance: AppearanceSettings()
      case .security: SecuritySettings(known: known, store: store, secrets: secrets)
      case .extensions: ExtensionSettings(registry: registry)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(section.title)
  }
}

/// What the app does on its own, before anyone has asked for anything.
///
/// Emits form sections only — the caller owns the `Form`, so a Mac's one
/// scrolling sheet and a phone's pushed pane share the same rows.
private struct GeneralSettings: View {
  @AppStorage(LaunchPreference.key) private var openLocalAtLaunch = LaunchPreference.default

  var body: some View {
    SwiftUI.Section("On Launch") {
      Toggle("Open Local Terminal", isOn: $openLocalAtLaunch)
    }
  }
}

private struct AppearanceSettings: View {
  @AppStorage("appearance") private var appearance = "system"
  @AppStorage("terminalAppearance") private var terminalAppearance = "system"
  @AppStorage("terminalFontSize") private var fontSize = 13.0

  var body: some View {
    SwiftUI.Section("Appearance") {
      Picker("Window", selection: $appearance) {
        Text("System").tag("system")
        Text("Light").tag("light")
        Text("Dark").tag("dark")
      }
      Picker("Terminal", selection: $terminalAppearance) {
        Text("System").tag("system")
        Text("Light").tag("light")
        Text("Dark").tag("dark")
      }
      Stepper("Font Size: \(Int(fontSize)) pt", value: $fontSize, in: 10...24)
    }
  }
}

/// The only place extensions are turned on and off.
///
/// Nowhere else in the app lists them as a thing to manage: what an enabled
/// extension contributes shows up as its own buttons, in the window, where
/// the work is. A list of extensions beside a list of hosts asks a person to
/// care about the plumbing every time they pick a machine.
private struct ExtensionSettings: View {
  let registry: PluginRegistry

  var body: some View {
    if registry.plugins.isEmpty {
      SwiftUI.Section("Extensions") {
        ContentUnavailableView(
          "No Extensions",
          systemImage: "puzzlepiece.extension")
      }
    }

    ForEach(registry.plugins, id: \.metadata.id) { plugin in
      let enabled = registry.isEnabled(plugin.metadata.id)

      SwiftUI.Section {
        Toggle(
          isOn: Binding(
            get: { registry.isEnabled(plugin.metadata.id) },
            set: { registry.setEnabled($0, id: plugin.metadata.id) })
        ) {
          Label(plugin.metadata.name, systemImage: plugin.metadata.symbol)
        }
        .help(plugin.metadata.summary)

        // An extension's own settings are meaningless while it is off, and
        // showing them anyway invites someone to change something that
        // will not take effect.
        if enabled {
          plugin.settings()
        }
      }
    }
  }
}

/// What this app has been told to trust and what it has been told to keep.
///
/// Both lists exist for one reason: a decision a person made once must be
/// visible and reversible. "Trust this host key" and "remember this password"
/// are the two places where a single click has consequences that outlive the
/// session — and until there is a screen like this, the only way back is to
/// find a JSON file, or to guess that the answer is in Keychain Access.
private struct SecuritySettings: View {
  let known: KnownHosts
  let store: HostStore
  let secrets: any SecretStore

  @State private var saved: [SavedSecret] = []
  @State private var problem: String?
  @State private var forgetting: KnownHost?

  var body: some View {
    Group {
      SwiftUI.Section {
      if known.entries.isEmpty {
        Text("None")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ForEach(known.entries, id: \.endpoint) { entry in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: UIStyle.Space.tight) {
            Text(entry.endpoint)
            // The fingerprint in full, in a monospaced face: it is the thing
            // an administrator publishes, and a person checking one against
            // the other needs every character of it.
            Text("\(entry.algorithm) \(entry.fingerprint)")
              .font(.caption.monospaced())
              .fixedSize(horizontal: false, vertical: true)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Spacer()
          Button("Forget") { forgetting = entry }
            .buttonStyle(.borderless)
        }
      }
    } header: {
      Text("Trusted Host Keys")
    }

    SwiftUI.Section {
      if saved.isEmpty {
        Text("None")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ForEach(saved) { secret in
        HStack {
          // The host's current name when it still exists, the label the
          // keychain carries when it does not. An entry whose host was
          // deleted is not hidden: it is the one most worth removing.
          Text(store.hosts.first { $0.id == secret.id }.map(\.address) ?? secret.label)
          Spacer()
          Button("Delete", role: .destructive) { delete(secret) }
            .buttonStyle(.borderless)
        }
      }
    } header: {
      Text("Saved Passwords")
    }

    if let problem {
      SwiftUI.Section {
        Text(problem).font(.callout).foregroundStyle(Theme.danger)
      }
    }
    }
    .onAppear(perform: reload)
    .confirmationDialog(
      "Forget this host key?",
      isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
      presenting: forgetting
    ) { entry in
      Button("Forget \(entry.endpoint)", role: .destructive) {
        known.forget(entry.endpoint)
        forgetting = nil
      }
      Button("Cancel", role: .cancel) { forgetting = nil }
    } message: { _ in
      Text("You’ll be asked to trust this host again when connecting.")
    }
  }

  private func reload() {
    do {
      saved = try secrets.saved()
      problem = nil
    } catch {
      // An empty list and no explanation would read as "nothing is saved",
      // which is the one thing this screen must never say by accident.
      saved = []
      problem = error.localizedDescription
    }
  }

  private func delete(_ secret: SavedSecret) {
    do {
      try secrets.forget(secret.id)
      if var host = store.hosts.first(where: { $0.id == secret.id }) {
        host.remembersPassword = false
        store.save(host)
      }
      reload()
    } catch {
      problem = error.localizedDescription
    }
  }
}
