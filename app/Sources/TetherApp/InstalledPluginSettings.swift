import SwiftUI
import UniformTypeIdentifiers
import TetherPluginHost
import TetherPluginKit
import TetherUI

struct InstalledPluginSettings: View {
  let library: InstalledPlugins
  let registry: PluginRegistry
  @State private var importing = false
  @State private var address = ""
  @State private var installing = false
  @State private var problem: String?
  @State private var removing: String?

  var body: some View {
    Section {
      ForEach(library.pluginIDs.sorted(), id: \.self) { id in
        if let plugin = registry.plugins.first(where: { $0.metadata.id == id }) {
          HStack {
            Toggle(isOn: Binding(get: { registry.isEnabled(id) }, set: { registry.setEnabled($0, id: id) })) {
              Label(plugin.metadata.name, systemImage: plugin.metadata.symbol)
            }
            .toggleStyle(.switch)
            .help(plugin.metadata.summary)
            SettingsAction("Uninstall \(plugin.metadata.name)", systemImage: "trash", role: .destructive) { removing = id }
          }
          if registry.isEnabled(id) { plugin.settings() }
        }
      }
      ForEach(library.problems, id: \.self) { issue in
        Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      HStack {
        TextField("GitHub", text: $address, prompt: Text("github.com/owner/repo"))
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .submitLabel(.done)
          #endif
          .disabled(installing)
          .onSubmit(installRepository)
          .accessibilityLabel("GitHub repository")
        SettingsAction("Install Latest Release", systemImage: "arrow.down", action: installRepository)
          .disabled(installing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    } header: {
      HStack {
        Text("Installed Packages")
        Spacer()
        SettingsAction("Install Plugin", systemImage: "plus") { importing = true }
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
      switch result {
      case .success(let url):
        Task { @MainActor in
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          do { try await library.install(directory: url) }
          catch PluginHostError.consentDenied { }
          catch { problem = error.localizedDescription }
        }
      case .failure(let error): problem = error.localizedDescription
      }
    }
    .dialog(for: problem) { message in
      Dialog.notice("Could Not Install Plugin", message: message) { problem = nil }
    }
    .dialog(for: removing) { id in
      let name = registry.plugins.first(where: { $0.metadata.id == id })?.metadata.name ?? id
      return Dialog.confirm("Uninstall \(name)?", verb: "Uninstall", role: .destructive,
                     cancel: { removing = nil }) {
        do { try library.uninstall(id: id) }
          catch PluginHostError.consentDenied { }
          catch { problem = error.localizedDescription }
        removing = nil
      }
    }
  }

  private func installRepository() {
    guard !installing else { return }
    let typed = address
    installing = true
    Task { @MainActor in
      defer { installing = false }
      do {
        try await library.install(repository: typed)
        address = ""
      } catch PluginHostError.consentDenied {
      } catch {
        problem = error.localizedDescription
      }
    }
  }
}
