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
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("Ctrl") }
    if modifiers.contains(.option) { parts.append("Alt") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    if modifiers.contains(.command) { parts.append("⌘") }
    parts.append(Self.namedKeys[key] ?? key.uppercased())
    return parts.joined(separator: "+")
  }
}

struct KeyBindingCommand: Identifiable, Equatable {
  let id: String
  let title: String
  let group: String
  var defaults: [KeyBinding?] = [nil, nil]
}

/// Only overrides are persisted: clearing a default is different from inheriting it.
@MainActor @Observable
final class KeyBindingStore {
  static let preferenceKey = "keyBindings.v1"
  private(set) var overrides: [String: [KeyBinding?]]
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let decoded = defaults.data(forKey: Self.preferenceKey).flatMap {
      try? JSONDecoder().decode([String: [KeyBinding?]].self, from: $0)
    } ?? [:]
    overrides = decoded.filter { _, bindings in
      bindings.count == 2 && bindings.compactMap { $0 }.allSatisfy(\.isValid)
    }
  }

  func bindings(for command: KeyBindingCommand) -> [KeyBinding?] {
    overrides[command.id] ?? command.defaults
  }

  func summary(for command: KeyBindingCommand) -> String {
    bindings(for: command).compactMap { $0?.label }.joined(separator: " / ")
  }

  func filtered(_ commands: [KeyBindingCommand], query: String, boundOnly: Bool) -> [KeyBindingCommand] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return commands.filter {
      (!boundOnly || bindings(for: $0).contains { $0 != nil })
        && (query.isEmpty || "\($0.title) \($0.group) \($0.id) \(summary(for: $0))"
          .localizedCaseInsensitiveContains(query))
    }
  }

  /// Validation is atomic; a rejected assignment leaves both slots untouched.
  func set(_ binding: KeyBinding?, for command: KeyBindingCommand, slot: Int,
           commands: [KeyBindingCommand]) throws {
    guard (0..<2).contains(slot) else { return }
    if let binding {
      guard binding.isValid else { throw BindingError.invalid }
      for other in commands {
        for (index, existing) in bindings(for: other).enumerated()
          where other.id != command.id || index != slot {
          if binding == existing { throw BindingError.conflict(other.title) }
        }
      }
    }
    var pair = bindings(for: command)
    pair[slot] = binding
    overrides[command.id] = pair
    persist()
  }

  func reset(_ command: KeyBindingCommand, commands: [KeyBindingCommand]) throws {
    for binding in command.defaults.compactMap({ $0 }) {
      if let other = commands.first(where: {
        $0.id != command.id && bindings(for: $0).contains(binding)
      }) { throw BindingError.conflict(other.title) }
    }
    overrides[command.id] = nil
    persist()
  }

  func resetAll() {
    overrides = [:]
    defaults.removeObject(forKey: Self.preferenceKey)
  }

  func command(for binding: KeyBinding, in commands: [KeyBindingCommand]) -> String? {
    commands.first { bindings(for: $0).contains(binding) }?.id
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(overrides) {
      defaults.set(data, forKey: Self.preferenceKey)
    }
  }

  enum BindingError: LocalizedError {
    case invalid
    case conflict(String)
    var errorDescription: String? {
      switch self {
      case .invalid: "Use Ctrl, Alt or Command with a key, or a function key."
      case .conflict(let title): "Already assigned to \(title). Clear that binding first."
      }
    }
  }
}
