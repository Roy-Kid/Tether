import SwiftUI
import TetherPluginKit

/// Settings, as two panes rather than a row of tabs.
///
/// A tab strip puts every section on screen at once and then hides all but
/// one of them, which stops scaling the moment a third section exists. A
/// sidebar is the same shape as the rest of the app, so the window a person
/// already knows how to read does not change its rules when they open
/// preferences.
struct AppSettings: View {
  let registry: PluginRegistry

  @State private var section: Section? = .appearance
  @AppStorage("appearance") private var appearance = "system"

  private enum Section: String, Identifiable, CaseIterable {
    case appearance
    case extensions

    var id: String { rawValue }

    var title: String {
      switch self {
      case .appearance: "Appearance"
      case .extensions: "Extensions"
      }
    }

    var symbol: String {
      switch self {
      case .appearance: "paintpalette"
      case .extensions: "puzzlepiece.extension"
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      List(Section.allCases, selection: $section) { section in
        Label(section.title, systemImage: section.symbol).tag(section)
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
    } detail: {
      switch section ?? .appearance {
      case .appearance: AppearanceSettings()
      case .extensions: ExtensionSettings(registry: registry)
      }
    }
    .frame(width: 680, height: 420)
    .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
  }
}

private struct AppearanceSettings: View {
  @AppStorage("appearance") private var appearance = "system"
  @AppStorage("terminalAppearance") private var terminalAppearance = "system"
  @AppStorage("terminalFontSize") private var fontSize = 13.0

  var body: some View {
    Form {
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
        Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 10...24)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Appearance")
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
    Form {
      if registry.plugins.isEmpty {
        ContentUnavailableView(
          "No extensions installed",
          systemImage: "puzzlepiece.extension",
          description: Text("Extensions add workspaces to a connected host."))
      }

      ForEach(registry.plugins, id: \.metadata.id) { plugin in
        let enabled = registry.isEnabled(plugin.metadata.id)

        SwiftUI.Section {
          Toggle(
            isOn: Binding(
              get: { registry.isEnabled(plugin.metadata.id) },
              set: { registry.setEnabled($0, id: plugin.metadata.id) })
          ) {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text(plugin.metadata.name)
                Text(plugin.metadata.summary).font(.caption).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: plugin.metadata.symbol)
            }
          }

          // An extension's own settings are meaningless while it is off, and
          // showing them anyway invites someone to change something that
          // will not take effect.
          if enabled {
            plugin.settings()
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Extensions")
  }
}
