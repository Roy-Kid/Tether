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
// Component previews deliberately omit the workspace shell. Composing a tab
// bar over EmptyWorkspace made a populated workspace look like an old screen.
#Preview("Tab bar · twenty tabs", traits: .fixedLayout(width: 860, height: Chrome.tab)) {
  WorkspaceTabBar(tabs: InterfaceFixture.tabs(), onClose: { _ in })
}

#Preview("Tab sidebar · twenty tabs", traits: .fixedLayout(width: Chrome.tabSidebarIdeal, height: 520)) {
  WorkspaceTabBar(tabs: InterfaceFixture.tabs(), layout: .vertical, onClose: { _ in })
}

#endif
#endif
