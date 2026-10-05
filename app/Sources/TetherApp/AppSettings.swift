import SwiftUI
#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif
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

enum TabLayout: String {
  case horizontal, vertical

  static let preferenceKey = "tabLayout"
  static let `default`: Self = .horizontal
}

/// The last tab-bar visibility on this device, independent of layout and Zen.
enum TabBarPreference {
  static let key = "tabBarVisible"
  static let `default` = true
}

/// What happens once a close leaves the window with nothing open.
///
/// The key and the two values live together so the picker, the close path
/// and the test name the same strings. The default keeps today's window:
/// the status line already says there is nothing open.
enum LastTabPreference {
  static let key = "closeLastTab"
  static let stay = "stay"
  static let quit = "quit"
  static let `default` = stay

  static var chosen: String {
    UserDefaults.standard.string(forKey: key) ?? `default`
  }

  /// Leave, when that is what was chosen. Otherwise the caller has already
  /// landed on the empty window.
  @MainActor
  static func quitIfChosen() {
    guard chosen == quit else { return }
    #if os(macOS)
      NSApplication.shared.terminate(nil)
    #else
      UIApplication.shared.perform(Selector(("suspend")))
    #endif
  }
}

/// Settings, as a sidebar and a titled page.
///
/// The sidebar names each section beside its tinted mark. The page title
/// sits over a grouped form, and the Mac titlebar keeps only the traffic
/// lights. A phone has no room for two columns, so the same rows are the
/// list that pushes a pane.
struct AppSettings: View {
  let registry: PluginRegistry
  let known: KnownHosts
  let store: HostStore
  let secrets: any SecretStore
  var connections: TabSet? = nil

  #if os(macOS)
    /// Which pane the split view is showing. A phone pushes instead.
    @State private var section: Section? = Section.available.first
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
  #endif
  @AppStorage("appearance") private var appearance = "system"
  @State private var fallbackKeyBindings = KeyBindingStore()

  private enum Section: String, Identifiable, CaseIterable {
    case general
    case appearance
    case history
    case keyBindings
    case security
    case identities
    case extensions

    var id: String { rawValue }

    var title: String {
      switch self {
      case .general: "General"
      case .appearance: "Appearance"
      case .history: "Session History"
      case .keyBindings: "Key Bindings"
      case .security: "Security"
      case .identities: "Identities"
      case .extensions: "Extensions"
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape.fill"
      case .appearance: "paintpalette.fill"
      case .history: "clock.arrow.circlepath"
      case .keyBindings: "keyboard.fill"
      case .security: "lock.shield.fill"
      case .identities: "person.badge.key.fill"
      case .extensions: "puzzlepiece.extension.fill"
      }
    }

    var subtitle: String {
      switch self {
      case .general: "What opens when Tether launches"
      case .appearance: "Window, terminal, and drawing"
      case .history: "Terminal content saved on this device"
      case .keyBindings: "Two shortcuts for every command"
      case .security: "Host keys and saved passwords"
      case .identities: "Hosts, keys, iCloud, and SSH configuration"
      case .extensions: "Accessories on a terminal tab"
      }
    }

    var tint: Color {
      switch self {
      case .general: .gray
      case .appearance: .indigo
      case .history: .blue
      case .keyBindings: .blue
      case .security: .orange
      case .identities: .teal
      case .extensions: .purple
      }
    }

    /// Sections a platform has nothing to put in are not shown empty.
    static var available: [Self] {
      allCases.filter {
        #if !os(macOS)
          if $0 == .keyBindings { return false }
        #endif
        return $0 != .general || TerminalSession.isLocalAvailable
      }
    }
  }

  var body: some View {
    #if os(macOS)
      NavigationSplitView(columnVisibility: $columnVisibility) {
        List(Section.available, selection: $section) { item in
          SettingsSidebarLabel(title: item.title, systemImage: item.symbol, tint: item.tint)
            .tag(item)
            .accessibilityLabel(item.title)
        }
        .listStyle(.sidebar)
        .onPickerNavigation { movement in
          var choice = PickerSelection(id: section)
          choice.navigate(movement, in: Section.available)
          section = choice.id
        }
        .navigationSplitViewColumnWidth(
          min: Chrome.settingsSidebarMin,
          ideal: Chrome.settingsSidebarIdeal,
          max: Chrome.settingsSidebarMax)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          settingsFooter
        }
      } detail: {
        pane(section ?? Section.available[0])
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .navigationSplitViewStyle(.balanced)
      .toolbar(removing: .sidebarToggle)
      .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
      .frame(minWidth: section == .keyBindings ? 820 : Chrome.settingsMinWidth, maxWidth: .infinity, minHeight: Chrome.settingsMinHeight, maxHeight: .infinity)
      .background { SettingsWindowChrome() }
      .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    #else
      // The caller already supplies the stack and its Done button, so this
      // is the list and nothing around it.
      List(Section.available) { section in
        NavigationLink {
          pane(section)
        } label: {
          SettingsSidebarLabel(title: section.title, systemImage: section.symbol, tint: section.tint)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        settingsFooter
      }
      .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    #endif
  }

  private var settingsFooter: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: UIStyle.Space.group) {
        appMark
          .frame(width: UIStyle.Mark.icon, height: UIStyle.Mark.icon)
          .accessibilityHidden(true)

        Text("Tether")
          .font(.caption.weight(.medium))

        Spacer(minLength: UIStyle.Space.small)

        Text("v\(appVersion)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, UIStyle.Space.inset)
      .padding(.vertical, UIStyle.panelRadius)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Tether \(appVersion)")
    }
    .background(.ultraThinMaterial)
  }

  @ViewBuilder
  private var appMark: some View {
    #if os(macOS)
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
    #else
      if let image = Bundle.main.appIcon {
        Image(uiImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: "terminal.fill")
          .font(UIStyle.symbol)
          .foregroundStyle(Theme.subtle)
      }
    #endif
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  @ViewBuilder
  private func pane(_ section: Section) -> some View {
    SettingsPage(title: section.title, subtitle: section.subtitle) {
      #if os(macOS)
        if section == .keyBindings {
          KeyBindingSettings(
            store: connections?.keyBindings ?? fallbackKeyBindings,
            commands: KeyBindingCatalog.commands(registry: registry, tabs: connections))
        } else {
          form(section)
        }
      #else
        form(section)
      #endif
    }
    #if os(iOS)
      // The page already shows the section title, the same as the Mac pane
      // under a titlebar that keeps only the traffic lights. A second copy
      // in the navigation bar is the title written twice.
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  private func form(_ section: Section) -> some View {
    Form {
      switch section {
      case .identities:
        IdentitySettings(store: store, connections: connections)
        DeviceSettings(store: store, known: known)
        SyncSettings(store: store)
      case .general: GeneralSettings()
      case .appearance: AppearanceSettings()
      case .history: HistorySettings()
      case .keyBindings:
        // This pane owns its scroll area so its search field can stay fixed.
        EmptyView()
      case .security: SecuritySettings(known: known, store: store, secrets: secrets)
      case .extensions: ExtensionSettings(registry: registry)
      }
    }
    .formStyle(.grouped)
    #if os(macOS)
      .scrollContentBackground(.hidden)
    #endif
  }
}

private struct SettingsSidebarLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
      Label {
        Text(title)
      } icon: {
        ZStack {
          RoundedRectangle(cornerRadius: UIStyle.badgeRadius, style: .continuous)
            .fill(tint.gradient)
            .frame(width: UIStyle.Mark.badge, height: UIStyle.Mark.badge)

          Image(systemName: systemImage)
            .font(UIStyle.symbol)
            .foregroundStyle(.white)
        }
      }
      .padding(.vertical, UIStyle.Space.tight)
    }
  }

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: UIStyle.Space.small) {
          Text(title)
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UIStyle.Space.wide)
        .padding(.top, UIStyle.Space.page)
        .padding(.bottom, UIStyle.panelRadius)

        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background(Theme.window)
    }
  }

private struct PreferenceToggleRow: View {
  let title: String
  let description: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(title, isOn: $isOn)
      .toggleStyle(.switch)
      .help(description)
  }
}

/// What the app does on its own, before anyone has asked for anything.
///
/// Emits form sections only — the caller owns the `Form`, so a Mac's one
/// scrolling sheet and a phone's pushed pane share the same rows.
private struct GeneralSettings: View {
  @AppStorage(LaunchPreference.key) private var openLocalAtLaunch = LaunchPreference.default
  @AppStorage(LastTabPreference.key) private var closeLastTab = LastTabPreference.default

  var body: some View {
    SwiftUI.Section("On Launch") {
      PreferenceToggleRow(
        title: "Open Local Terminal",
        description: "Open a local shell instead of the host list.",
        isOn: $openLocalAtLaunch)
    }

    SwiftUI.Section("When the Last Tab Closes") {
      Picker("After the Last Tab", selection: $closeLastTab) {
        Text("No open terminals").tag(LastTabPreference.stay)
        Text("Quit").tag(LastTabPreference.quit)
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
  }
}

private struct AppearanceSettings: View {
  @AppStorage("appearance") private var appearance = "system"
  @AppStorage("terminalAppearance") private var terminalAppearance = "system"
  @AppStorage("terminalFontSize") private var fontSize = 13.0
  @AppStorage("terminalDrawing") private var drawing = TerminalDrawing.platformDefault
  @AppStorage(TabLayout.preferenceKey) private var tabLayout = TabLayout.default

  var body: some View {
    SwiftUI.Section("Window") {
      Picker("Appearance", selection: $appearance) {
        Text("System").tag("system")
        Text("Light").tag("light")
        Text("Dark").tag("dark")
      }
      #if os(macOS)
        Picker("Tab Layout", selection: $tabLayout) {
          Text("Horizontal").tag(TabLayout.horizontal)
          Text("Vertical").tag(TabLayout.vertical)
        }
      #endif
    }

    SwiftUI.Section("Terminal") {
      Picker("Theme", selection: $terminalAppearance) {
        Text("System").tag("system")
        Text("Light").tag("light")
        Text("Dark").tag("dark")
      }
      Stepper("Font Size: \(Int(fontSize)) pt", value: $fontSize, in: 10...24)
      Picker("Drawing", selection: $drawing) {
        Text("Canvas").tag(TerminalDrawing.canvas.rawValue)
        Text("Metal").tag(TerminalDrawing.metal.rawValue)
      }
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
        .toggleStyle(.switch)
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
    .dialog(for: forgetting) { entry in
      Dialog.confirm(
        "Forget \(entry.endpoint)?", message: "You’ll be asked to trust this host again when connecting.",
        verb: "Forget", role: .destructive, cancel: { forgetting = nil }
      ) {
        known.forget(entry.endpoint)
        forgetting = nil
      }
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

private struct HistorySettings: View {
  @AppStorage(HistoryPreference.linesKey) private var lines = HistoryPreference.defaultLines
  @AppStorage(HistoryPreference.unlimitedKey) private var unlimited = false

  var body: some View {
    SwiftUI.Section {
      Toggle("Unlimited", isOn: $unlimited)
      if !unlimited {
        TextField("Lines per Session", value: $lines, format: .number.grouping(.never))
          .onChange(of: lines) { _, value in if value < 1 { lines = 1 } }
      }
    } header: {
      Text("Saved History")
    } footer: {
      Text("Keeps the most recent lines plus the current screen. Applies to newly opened or restored sessions. Unlimited history uses more disk space.")
    }
    SwiftUI.Section {
      LabeledContent("Recently Closed Tabs", value: "20")
    } footer: {
      Text("Session content is stored only on this device. Restoring a tab starts a new shell or connection; running processes are not restored.")
    }
  }
}

#if os(iOS)
  extension Bundle {
    /// The same mark the Mac footer takes from `NSApp.applicationIconImage`.
    fileprivate var appIcon: UIImage? {
      guard
        let icons = object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
        let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
        let files = primary["CFBundleIconFiles"] as? [String],
        let name = files.last
      else { return nil }
      return UIImage(named: name)
    }
  }
#endif
