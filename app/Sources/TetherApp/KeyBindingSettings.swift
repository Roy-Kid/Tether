import SwiftUI
import TetherUI

struct KeyBindingSettings: View {
  let store: KeyBindingStore
  let commands: [KeyBindingCommand]
  var onRecordingChange: (Bool) -> Void = { _ in }
  @State private var query = ""
  @State private var grouped = true
  @State private var recording: Slot?
  @State private var problem: String?

  private struct Slot: Equatable {
    let command: String
    let index: Int
  }

  private var filtered: [KeyBindingCommand] {
    store.filtered(commands, query: query, boundOnly: false)
  }

  var body: some View {
    Form {
      commandList
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    // Inset, so a pinned section title stays below the field.
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        searchBar
        Divider()
      }
      .frame(maxWidth: .infinity)
      .background(Theme.window)
    }
    .onChange(of: recording != nil) { _, recording in onRecordingChange(recording) }
    .onDisappear { onRecordingChange(false) }
    .onChange(of: commands, initial: true) { _, commands in store.register(commands) }
  }

  private var searchBar: some View {
    HStack(spacing: UIStyle.Space.section) {
      TextField("Search key bindings", text: $query, prompt: Text("Search commands or shortcuts"))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .accessibilityLabel("Search key bindings")

      Button {
        grouped.toggle()
      } label: {
        Image(systemName: "rectangle.3.group")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(grouped ? Color.accentColor : Color.secondary)
          .frame(width: 28, height: 24)
          .contentShape(Rectangle())
          .help("Group by Feature")
      }
      .buttonStyle(ChromeButtonStyle(selected: grouped))
      .accessibilityLabel("Group by feature")
      .accessibilityValue(grouped ? "On" : "Off")
      .accessibilityAddTraits(grouped ? .isSelected : [])
    }
    // Leading matches the grouped form margin, so the field lines up with the rows.
    .padding(.leading, UIStyle.Space.section + UIStyle.Space.small)
    .padding(.trailing, UIStyle.Space.wide)
    .padding(.vertical, UIStyle.Space.group)
  }

  @ViewBuilder
  private var commandList: some View {
    if let problem {
      Section { Text(problem).foregroundStyle(Theme.danger).accessibilityLabel("Shortcut error: \(problem)") }
    }
    if commands.contains(where: { command in (0..<2).contains { store.conflict(for: command, slot: $0) != nil } }) {
      Section {
        Text("Shortcuts in orange conflict and are inactive.")
          .foregroundStyle(Theme.warning)
      }
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
    let modified = store.requestedBindings(for: command) != command.defaults
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
    let binding = store.requestedBindings(for: command)[slot]
    let conflict = store.conflict(for: command, slot: slot)
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
          .foregroundStyle(conflict != nil ? Theme.warning : modified ? Color.accentColor : Color.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .frame(maxWidth: .infinity, minHeight: 22)
      }
      .buttonStyle(.bordered)
      .tint(conflict != nil ? Theme.warning : active || modified ? .accentColor : .secondary)
      .overlay {
        if modified {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder((conflict != nil ? Theme.warning : Color.accentColor).opacity(0.7), lineWidth: 1)
            .allowsHitTesting(false)
        }
      }
      .accessibilityLabel("\(command.title), \(name): \(binding?.accessibilityLabel ?? "Not set")")
      .accessibilityValue(conflict.map { "Inactive: " + $0 } ?? (modified ? "Modified from default" : "Default"))
      .help(conflict ?? (modified
        ? "Modified · Default: \(defaultLabel)"
        : binding?.label ?? "Record \(name.lowercased()) shortcut"))
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
