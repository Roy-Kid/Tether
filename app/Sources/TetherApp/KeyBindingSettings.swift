#if os(macOS)
import SwiftUI

struct KeyBindingSettings: View {
  let store: KeyBindingStore
  let commands: [KeyBindingCommand]
  @State private var query = ""
  @State private var boundOnly = false
  @State private var grouped = true
  @State private var recording: Slot?
  @State private var problem: String?

  private struct Slot: Equatable {
    let command: String
    let index: Int
  }

  private var filtered: [KeyBindingCommand] {
    store.filtered(commands, query: query, boundOnly: boundOnly)
  }

  var body: some View {
    Section {
      TextField("Search commands or shortcuts", text: $query)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .accessibilityLabel("Search key bindings")
      Toggle("Only commands with shortcuts", isOn: $boundOnly)
      Toggle("Group by feature", isOn: $grouped)
      HStack {
        Text("\(filtered.count) commands")
          .foregroundStyle(.secondary)
        Spacer()
        if commands.contains(where: { store.bindings(for: $0) != $0.defaults }) {
          Button("Reset All") {
            recording = nil
            problem = nil
            store.resetAll()
          }
        }
      }
      .frame(minHeight: 24)
    } footer: {
      Text("Click a shortcut and press a key combination. Alt is the Option key. Esc cancels recording. Assigned shortcuts take priority over terminal input.")
    }

    if let problem {
      Section { Text(problem).foregroundStyle(.red).accessibilityLabel("Shortcut error: \(problem)") }
    }
    if filtered.isEmpty {
      Section { Text("No matching commands").foregroundStyle(.secondary) }
    } else if grouped {
      ForEach(groups, id: \.self) { group in
        Section(group) {
          columnLabels
          ForEach(filtered.filter { $0.group == group }) { command in row(command) }
        }
      }
    } else {
      Section("Commands") {
        columnLabels
        ForEach(filtered) { command in row(command) }
      }
    }
  }

  private var groups: [String] {
    var seen = Set<String>()
    return filtered.map(\.group).filter { seen.insert($0).inserted }
  }

  private var columnLabels: some View {
    HStack {
      Text("Command").frame(maxWidth: .infinity, alignment: .leading)
      Text("Primary").frame(width: 128)
      Text("Secondary").frame(width: 128)
      Color.clear.frame(width: 20, height: 1)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func row(_ command: KeyBindingCommand) -> some View {
    let modified = store.bindings(for: command) != command.defaults
    return HStack(spacing: 8) {
      Text(command.title)
        .foregroundStyle(modified ? Color.accentColor : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(command.id)
      shortcut(command, slot: 0)
      shortcut(command, slot: 1)
      Group {
        if modified {
          Button {
            recording = nil
            do { try store.reset(command, commands: commands); problem = nil }
            catch { problem = error.localizedDescription }
          } label: { Image(systemName: "arrow.counterclockwise") }
          .buttonStyle(.borderless)
          .help("Reset \(command.title)")
          .accessibilityLabel("Reset \(command.title)")
        } else {
          Color.clear.allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .frame(width: 20, height: 22)
    }
    .padding(.vertical, 3)
  }

  private func shortcut(_ command: KeyBindingCommand, slot: Int) -> some View {
    let target = Slot(command: command.id, index: slot)
    let active = recording == target
    let binding = store.bindings(for: command)[slot]
    let modified = binding != command.defaults[slot]
    let name = slot == 0 ? "Primary" : "Secondary"
    let defaultLabel = command.defaults[slot]?.label ?? "Not set"
    return HStack(spacing: 2) {
      Button {
        problem = nil
        recording = active ? nil : target
      } label: {
        Text(active ? "Press keys…" : binding?.label ?? "Not set")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(modified ? Color.accentColor : Color.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .frame(maxWidth: .infinity, minHeight: 22)
      }
      .buttonStyle(.bordered)
      .tint(active || modified ? .accentColor : .secondary)
      .overlay {
        if modified {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
            .allowsHitTesting(false)
        }
      }
      .accessibilityLabel("\(command.title), \(name): \(binding?.label ?? "Not set")")
      .accessibilityValue(modified ? "Modified from default" : "Default")
      .help(modified
        ? "Modified · Default: \(defaultLabel)"
        : binding?.label ?? "Record \(name.lowercased()) shortcut")
      Group {
        if binding != nil {
          Button {
            recording = nil
            do { try store.set(nil, for: command, slot: slot, commands: commands); problem = nil }
            catch { problem = error.localizedDescription }
          } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Clear \(name.lowercased()) shortcut for \(command.title)")
          .help("Clear shortcut")
        } else {
          Color.clear.allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .frame(width: 16, height: 22)
    }
    .frame(width: 128)
    .background {
      if active {
        KeyBindingRecorder { recorded in
          guard let recorded else {
            problem = KeyBindingStore.BindingError.invalid.localizedDescription
            return
          }
          do {
            try store.set(recorded, for: command, slot: slot, commands: commands)
            recording = nil
            problem = nil
          } catch { problem = error.localizedDescription }
        } cancel: {
          if recording == target { recording = nil }
        }
        .frame(width: 0, height: 0)
      }
    }
  }
}
#endif
