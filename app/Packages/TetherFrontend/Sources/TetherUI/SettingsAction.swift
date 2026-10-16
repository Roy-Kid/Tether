import SwiftUI

/// Compact settings actions retain their names for hover and VoiceOver.
public struct SettingsAction: View {
  private let title: String
  private let symbol: String
  private let role: ButtonRole?
  private let action: () -> Void

  public init(_ title: String, systemImage: String, role: ButtonRole? = nil,
              action: @escaping () -> Void) {
    self.title = title; symbol = systemImage; self.role = role; self.action = action
  }

  public var body: some View {
    Button(role: role, action: action) {
      Label(title, systemImage: symbol)
        .labelStyle(.iconOnly)
        .font(UIStyle.symbol)
        .frame(minWidth: UIStyle.controlHeight, minHeight: UIStyle.controlHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(title)
    .accessibilityLabel(title)
  }
}
