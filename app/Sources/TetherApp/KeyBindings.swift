import Foundation
import Observation

struct KeyModifiers: OptionSet, Codable, Hashable {
  let rawValue: Int
  static let control = Self(rawValue: 1 << 0)
  static let option = Self(rawValue: 1 << 1)
  static let shift = Self(rawValue: 1 << 2)
  static let command = Self(rawValue: 1 << 3)
  static let all: Self = [.control, .option, .shift, .command]
}

/// A logical key, independent of a physical keyboard layout. Option is Meta/Alt.
struct KeyBinding: Codable, Hashable {
  let key: String
  let modifiers: KeyModifiers

  init(_ key: String, _ modifiers: KeyModifiers = .command) {
    self.key = key.lowercased()
    self.modifiers = modifiers.intersection(.all)
  }

  static let namedKeys: [String: String] = [
    "left": "←", "right": "→", "up": "↑", "down": "↓",
    "return": "Return", "tab": "Tab", "space": "Space", "escape": "Esc",
    "backspace": "⌫", "delete": "⌦", "home": "Home", "end": "End",
    "pageup": "Page Up", "pagedown": "Page Down",
  ]

  var isFunctionKey: Bool {
    guard key.hasPrefix("f"), let number = Int(key.dropFirst()) else { return false }
    return (1...20).contains(number) && key == "f\(number)"
  }

  var isValid: Bool {
    let character = key.count == 1 && key.unicodeScalars.allSatisfy {
      !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
    }
    return key == key.lowercased() && modifiers.subtracting(.all).isEmpty
      && (character || Self.namedKeys[key] != nil || isFunctionKey)
      && (!modifiers.intersection([.control, .option, .command]).isEmpty || isFunctionKey)
  }

  var label: String {
    #if os(macOS)
      modifierLabels.map(\.symbol).joined() + keyLabel
    #else
      legacyLabel
    #endif
  }

  /// Spoken names stay readable even when the visible shortcut uses symbols.
  var accessibilityLabel: String {
    (modifierLabels.map(\.name) + [keyLabel]).joined(separator: "+")
  }

  /// Display notation must not make shortcuts harder to find by typing.
  var searchLabels: [String] {
    [label, accessibilityLabel, legacyLabel,
     legacyLabel.replacingOccurrences(of: "Alt+", with: "Option+")
       .replacingOccurrences(of: "⌘+", with: "Cmd+")]
  }

  private var keyLabel: String { Self.namedKeys[key] ?? key.uppercased() }

  private var modifierLabels: [(symbol: String, name: String)] {
    [
      (KeyModifiers.control, "⌃", "Control"),
      (KeyModifiers.option, "⌥", "Option"),
      (KeyModifiers.shift, "⇧", "Shift"),
      (KeyModifiers.command, "⌘", "Command"),
    ].compactMap { modifiers.contains($0.0) ? (symbol: $0.1, name: $0.2) : nil }
  }

  private var legacyLabel: String {
    accessibilityLabel
      .replacingOccurrences(of: "Control+", with: "Ctrl+")
      .replacingOccurrences(of: "Option+", with: "Alt+")
      .replacingOccurrences(of: "Command+", with: "⌘+")
  }
}

struct KeyBindingCommand: Identifiable, Equatable {
  let id: String
  let title: String
  let group: String
  var defaults: [KeyBinding?] = [nil, nil]
}

/// Local preferences and a durable outbox, partitioned by Apple account.
@MainActor @Observable
final class KeyBindingStore {
  static let preferenceKey = "keyBindings.v1"
  static let syncPreferenceKey = "keyBindings.sync.v1"
  private var archive: KeyBindingArchive
  private var knownCommands = WorkspaceAction.allCases.map(\.command)
  private let defaults: UserDefaults
  @ObservationIgnored var onChange: (() -> Void)?

  var account: String { archive.account }
  var entries: [String: KeyBindingSyncEntry] { archive.accounts[account] ?? [:] }
  var overrides: [String: [KeyBinding?]] { entries.compactMapValues(\.change.bindings) }
  var pending: [String] { entries.filter { $0.value.dirty }.keys.sorted() }
  var needsInitialCloudFetch: Bool { !archive.initializedAccounts.contains(account) }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.syncPreferenceKey),
      var saved = try? JSONDecoder().decode(KeyBindingArchive.self, from: data) {
      saved.accounts = saved.accounts.mapValues { $0.filter { $0.value.change.isValid } }
      archive = saved
    } else {
      let legacy = defaults.data(forKey: Self.preferenceKey).flatMap {
        try? JSONDecoder().decode([String: [KeyBinding?]].self, from: $0)
      } ?? [:]
      // Existing preferences have no edit time. Cloud revisions win when the
      // same command already exists; untouched commands migrate independently.
      let entries = legacy.mapValues {
        KeyBindingSyncEntry(change: KeyBindingChange(bindings: $0,
          modified: .distantPast, token: UUID().uuidString))
      }.filter { $0.value.change.isValid }
      archive = KeyBindingArchive(accounts: ["local": entries])
    }
  }

  func register(_ commands: [KeyBindingCommand]) {
    var merged = Dictionary(uniqueKeysWithValues: knownCommands.map { ($0.id, $0) })
    for command in commands { merged[command.id] = command }
    let next = merged.values.sorted { $0.id < $1.id }
    if knownCommands != next { knownCommands = next }
  }

  func requestedBindings(for command: KeyBindingCommand) -> [KeyBinding?] {
    entries[command.id]?.change.bindings ?? command.defaults
  }

  /// Keep the losing assignment for review, but never dispatch a combination
  /// twice. Explicit assignments outrank defaults, then newest revision wins.
  func bindings(for command: KeyBindingCommand) -> [KeyBinding?] {
    requestedBindings(for: command).map { binding in
      guard let binding, winner(for: binding, including: command)?.id == command.id else { return nil }
      return binding
    }
  }

  func conflict(for command: KeyBindingCommand, slot: Int) -> String? {
    guard let binding = requestedBindings(for: command)[slot],
      let winner = winner(for: binding, including: command), winner.id != command.id else { return nil }
    return "\(binding.label) is active for \(winner.title). Reassign or clear this shortcut."
  }

  private func winner(for binding: KeyBinding, including command: KeyBindingCommand) -> KeyBindingCommand? {
    catalog(including: command).filter { requestedBindings(for: $0).contains(binding) }.sorted { a, b in
      let left = entries[a.id]?.change, right = entries[b.id]?.change
      let explicitLeft = left?.bindings != nil, explicitRight = right?.bindings != nil
      if explicitLeft != explicitRight { return explicitLeft }
      if explicitLeft, let left, let right,
        left.modified != right.modified || left.token != right.token { return left.isNewer(than: right) }
      return a.id < b.id
    }.first
  }

  private func catalog(including command: KeyBindingCommand) -> [KeyBindingCommand] {
    var all = Dictionary(uniqueKeysWithValues: knownCommands.map { ($0.id, $0) })
    all[command.id] = command
    // Preserve and reserve assignments from plugins absent on this device.
    for id in entries.keys where all[id] == nil {
      all[id] = KeyBindingCommand(id: id, title: id, group: "")
    }
    return Array(all.values)
  }

  func summary(for command: KeyBindingCommand) -> String {
    bindings(for: command).compactMap { $0?.label }.joined(separator: " / ")
  }

  func filtered(_ commands: [KeyBindingCommand], query: String, boundOnly: Bool) -> [KeyBindingCommand] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return commands.filter {
      let bindings = requestedBindings(for: $0).compactMap { $0 }
      let labels = bindings.flatMap(\.searchLabels).joined(separator: " / ")
      return (!boundOnly || !bindings.isEmpty)
        && (query.isEmpty || "\($0.title) \($0.group) \($0.id) \(labels)"
          .localizedCaseInsensitiveContains(query))
    }
  }

  /// Validation is atomic; a rejected assignment leaves both slots untouched.
  func set(_ binding: KeyBinding?, for command: KeyBindingCommand, slot: Int,
           commands: [KeyBindingCommand]) throws {
    guard (0..<2).contains(slot) else { return }
    register(commands)
    if let binding {
      guard binding.isValid else { throw BindingError.invalid }
      for other in catalog(including: command) {
        for (index, existing) in requestedBindings(for: other).enumerated()
          where other.id != command.id || index != slot {
          if binding == existing { throw BindingError.conflict(other.title) }
        }
      }
    }
    var pair = requestedBindings(for: command)
    pair[slot] = binding
    change(command.id, bindings: pair)
  }

  func reset(_ command: KeyBindingCommand, commands: [KeyBindingCommand]) throws {
    register(commands)
    for binding in command.defaults.compactMap({ $0 }) {
      if let other = catalog(including: command).first(where: {
        $0.id != command.id && requestedBindings(for: $0).contains(binding)
      }) { throw BindingError.conflict(other.title) }
    }
    change(command.id, bindings: nil)
  }

  func resetAll() {
    for id in overrides.keys { change(id, bindings: nil) }
  }

  func command(for binding: KeyBinding, in commands: [KeyBindingCommand]) -> String? {
    register(commands)
    return commands.first { bindings(for: $0).contains(binding) }?.id
  }

  func switchAccount(_ account: String) {
    guard account != archive.account else { return }
    archive.account = account
    if account.hasPrefix("icloud:") {
      var target = entries
      for (id, entry) in archive.accounts["local"] ?? [:] {
        if target[id] == nil || entry.change.isNewer(than: target[id]!.change) {
          target[id] = KeyBindingSyncEntry(change: entry.change)
        }
      }
      archive.accounts[account] = target
      // Move the local outbox once; signing into a different account cannot
      // export the previous account's settings or reimport stale preferences.
      archive.accounts["local"] = [:]
    }
    persist()
  }

  func receive(_ change: KeyBindingChange, for id: String, systemFields: Data?) throws {
    guard change.isValid else { throw IdentityError.invalidConfiguration }
    let local = entries[id]?.change
    let keepingLocal = local.map { $0.isNewer(than: change) } ?? false
    archive.accounts[account, default: [:]][id] = KeyBindingSyncEntry(
      change: keepingLocal ? local! : change, dirty: keepingLocal, systemFields: systemFields)
    persist()
  }

  func didFetchCloud() {
    guard needsInitialCloudFetch else { return }
    archive.initializedAccounts.insert(account)
    persist()
  }

  func didSave(_ sent: KeyBindingChange, for id: String, systemFields: Data) {
    guard var current = entries[id] else { return }
    // An edit made while a save was in flight stays in the outbox.
    current.systemFields = systemFields
    current.dirty = current.change != sent
    archive.accounts[account, default: [:]][id] = current
    persist()
  }

  func prepareReupload() {
    archive.accounts[account] = entries.mapValues { KeyBindingSyncEntry(change: $0.change) }
    persist()
  }

  func removeCloudRecords(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    for id in ids { archive.accounts[account]?[id] = nil }
    persist()
  }

  func retryMissingRecord(_ id: String) {
    guard let current = entries[id] else { return }
    archive.accounts[account]?[id] = KeyBindingSyncEntry(change: current.change)
    persist()
  }

  private func change(_ id: String, bindings: [KeyBinding?]?) {
    let latest = entries.values.map(\.change.modified).max() ?? .distantPast
    let modified = max(Date(), latest.addingTimeInterval(0.001))
    archive.accounts[account, default: [:]][id] = KeyBindingSyncEntry(
      change: KeyBindingChange(bindings: bindings, modified: modified, token: UUID().uuidString),
      systemFields: entries[id]?.systemFields)
    persist()
    onChange?()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(archive) {
      defaults.set(data, forKey: Self.syncPreferenceKey)
    }
    // Retain the old format for downgrades; the account archive is authoritative.
    if overrides.isEmpty {
      defaults.removeObject(forKey: Self.preferenceKey)
    } else if let data = try? JSONEncoder().encode(overrides) {
      defaults.set(data, forKey: Self.preferenceKey)
    }
  }

  enum BindingError: LocalizedError {
    case invalid
    case conflict(String)
    var errorDescription: String? {
      switch self {
      case .invalid:
        #if os(macOS)
          "Use ⌃, ⌥ or ⌘ with a key, or a function key."
        #else
          "Use Ctrl, Alt or Command with a key, or a function key."
        #endif
      case .conflict(let title): "Already assigned to \(title). Clear that binding first."
      }
    }
  }
}
