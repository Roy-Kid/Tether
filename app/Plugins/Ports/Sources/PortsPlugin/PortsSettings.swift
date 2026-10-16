import Foundation
import SwiftUI
import TetherUI

enum PortsPreferences {
  static let automaticKey = "plugin.dev.tether.ports.automatic"
  static let ignoreKey = "plugin.dev.tether.ports.ignore"

  static func automatic(_ defaults: UserDefaults = .standard) -> Bool {
    guard defaults.object(forKey: automaticKey) != nil else { return true }
    return defaults.bool(forKey: automaticKey)
  }

  static func ignored(_ defaults: UserDefaults = .standard) -> Set<UInt16> {
    PortScan.ignoredPorts(defaults.string(forKey: ignoreKey) ?? "")
  }
}

struct PortsSettings: View {
  @AppStorage(PortsPreferences.automaticKey) private var automatic = true
  @AppStorage(PortsPreferences.ignoreKey) private var ignore = ""

  var body: some View {
    VStack(alignment: .leading, spacing: UIStyle.Space.group) {
      Toggle("Automatic", isOn: $automatic)
        .help("Forward a port when it appears")
      TextField("Ignore", text: $ignore)
        .help("Ports left alone, separated by commas")
    }
  }
}
