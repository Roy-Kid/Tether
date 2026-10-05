import Foundation
import SwiftUI

#if os(macOS)
import AppKit

enum TerminalAction: String, CaseIterable, Identifiable {
  case copy, paste, zoomIn, zoomOut, zoomReset
  var id: String { rawValue }
  var title: String {
    switch self {
    case .copy: "Copy"
    case .paste: "Paste"
    case .zoomIn: "Zoom in"
    case .zoomOut: "Zoom out"
    case .zoomReset: "Reset zoom"
    }
  }
  var defaultChord: String {
    switch self {
    case .copy: "Cmd+C"
    case .paste: "Cmd+V"
    case .zoomIn: "Cmd+Shift+Equals"
    case .zoomOut: "Cmd+Minus"
    case .zoomReset: "Cmd+0"
    }
  }
}

struct TerminalShortcut: Hashable {
  let key: String
  let modifiers: NSEvent.ModifierFlags

  func hash(into hasher: inout Hasher) {
    hasher.combine(key)
    hasher.combine(modifiers.rawValue)
  }

  init?(_ text: String) {
    let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let last = parts.last, parts.count >= 2 else { return nil }
    let names = parts.dropLast()
    guard Set(names).count == names.count,
      names.allSatisfy({ ["cmd", "ctrl", "shift", "alt"].contains($0) }),
      names.contains("cmd") || names.contains("ctrl")
    else { return nil }
    var flags: NSEvent.ModifierFlags = []
    if names.contains("cmd") { flags.insert(.command) }
    if names.contains("ctrl") { flags.insert(.control) }
    if names.contains("shift") { flags.insert(.shift) }
    if names.contains("alt") { flags.insert(.option) }
    if last == "equals" { key = "=" }
    else if last == "minus" { key = "-" }
    else if last.count == 1, last.unicodeScalars.allSatisfy({
      (97...122).contains($0.value) || (48...57).contains($0.value)
    }) { key = last }
    else { return nil }
    modifiers = flags
  }

  func matches(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    var character = event.charactersIgnoringModifiers?.lowercased()
    if character == "+" { character = "=" }
    if character == "_" { character = "-" }
    return flags == modifiers && character == key
  }
}

enum TerminalShortcuts {
  static let storageKey = "terminalShortcuts"
  static var defaults: [String: String] {
    Dictionary(uniqueKeysWithValues: TerminalAction.allCases.map { ($0.rawValue, $0.defaultChord) })
  }
  static var current: [String: String] {
    let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    let result = defaults.merging(saved) { _, new in new }
    return validate(result) == nil ? result : defaults
  }
  static func validate(_ bindings: [String: String]) -> String? {
    var seen = Set<TerminalShortcut>()
    for action in TerminalAction.allCases {
      guard let chord = TerminalShortcut(bindings[action.rawValue] ?? "") else {
        return "Invalid shortcut for \(action.title)."
      }
      guard seen.insert(chord).inserted else { return "Each action needs a different shortcut." }
      // Preserve application commands such as Quit, Close and the command palette.
      if chord.modifiers == .command && ["q", "w", "h", "m", "n", "t"].contains(chord.key)
        || chord.modifiers == [.control, .shift] && chord.key == "p" {
        return "That shortcut is reserved by the application."
      }
    }
    return nil
  }
}

/// The host embeds this pane; input and its preferences share one definition.
public struct TerminalPreferencesEditor: View {
  @State private var bindings = TerminalShortcuts.current
  @State private var problem = ""
  @AppStorage("terminalPasteThreshold") private var threshold = 4096

  public init() {}
  public var body: some View {
    Form {
      Section("Shortcuts") {
        ForEach(TerminalAction.allCases) { action in
          TextField(action.title, text: Binding(
            get: { bindings[action.rawValue] ?? action.defaultChord },
            set: { bindings[action.rawValue] = $0 }))
        }
        Text("Use Cmd or Ctrl, optional Shift or Alt, and a letter, digit, Equals or Minus.")
          .font(.caption).foregroundStyle(.secondary)
        if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
        Button("Apply shortcuts") {
          problem = TerminalShortcuts.validate(bindings) ?? ""
          if problem.isEmpty { UserDefaults.standard.set(bindings, forKey: TerminalShortcuts.storageKey) }
        }
        Button("Restore shortcuts") {
          bindings = TerminalShortcuts.defaults
          UserDefaults.standard.removeObject(forKey: TerminalShortcuts.storageKey)
          problem = ""
        }
      }
      Section("Paste") {
        Stepper("Confirm at \(threshold) characters", value: $threshold, in: 1...1_000_000, step: 256)
        Text("Multi-line pastes always ask.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Terminal")
  }
}
#endif

enum TerminalPastePolicy {
  static func requiresConfirmation(_ text: String, threshold: Int) -> Bool {
    text.utf16.count >= max(1, threshold) || text.contains("\n") || text.contains("\r")
  }
}
