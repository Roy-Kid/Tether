#if DEBUG
import SwiftUI
import TetherUI

/// Offline fixtures: previews never dial a host, read a key, or modify SSH config.
private enum InterfaceFixture {
  static var host: Host {
    Host(label: "Research workstation", hostname: "workstation.example",
         port: 22, username: "researcher")
  }

  @MainActor static func tabs() -> TabSet {
    let tabs = TabSet()
    let fixtureHost = host
    let known = KnownHosts(location: URL(fileURLWithPath: "/dev/null"))
    for index in 1...20 {
      tabs.adopt(SessionTab(preview: fixtureHost, known: known,
        name: index == 20 ? "A terminal with a deliberately long name" : "Terminal \(index)",
        live: false))
    }
    return tabs
  }
}

#Preview("Host editor · light") {
  HostEditor(host: InterfaceFixture.host) { _, _ in true }
    .preferredColorScheme(.light)
}

#Preview("Host editor · dark") {
  HostEditor(host: InterfaceFixture.host) { _, _ in true }
    .preferredColorScheme(.dark)
}

#if os(macOS)
#Preview("Mac · twenty tabs", traits: .fixedLayout(width: 860, height: 520)) {
  VStack(spacing: 0) {
    WorkspaceTabBar(tabs: InterfaceFixture.tabs(), onClose: { _ in })
    EmptyWorkspace().frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  .background(Theme.window)
}

#Preview("Mac · vertical tabs", traits: .fixedLayout(width: 860, height: 520)) {
  HStack(spacing: 0) {
    WorkspaceTabBar(tabs: InterfaceFixture.tabs(), layout: .vertical, onClose: { _ in })
      .frame(width: Chrome.tabSidebarIdeal)
    Divider()
    EmptyWorkspace().frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  .background(Theme.window)
}
#endif
#endif
