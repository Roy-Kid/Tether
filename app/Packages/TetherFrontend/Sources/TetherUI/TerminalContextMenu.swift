import SwiftUI

/// App-owned terminal actions. The surface combines these with actions for links.
public struct TerminalMenuItem {
  public var title: String
  public var checked: Bool
  public var enabled: Bool
  public var children: [TerminalMenuItem]
  public var action: (@MainActor () -> Void)?

  public init(_ title: String, checked: Bool = false, enabled: Bool = true,
              children: [TerminalMenuItem] = [], action: (@MainActor () -> Void)? = nil) {
    self.title = title
    self.checked = checked
    self.enabled = enabled
    self.children = children
    self.action = action
  }

  public static var separator: Self { Self("") }
}

private struct TerminalMenuKey: EnvironmentKey {
  static var defaultValue: [TerminalMenuItem] { [] }
}

extension EnvironmentValues {
  var terminalMenuItems: [TerminalMenuItem] {
    get { self[TerminalMenuKey.self] }
    set { self[TerminalMenuKey.self] = newValue }
  }
}

extension View {
  public func terminalContextMenu(_ items: [TerminalMenuItem]) -> some View {
    environment(\.terminalMenuItems, items)
  }
}
