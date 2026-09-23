import SwiftUI
import Tether
import TetherUI

/// One tab's contents.
struct SessionView: View {
  let tab: SessionTab
  /// What pointing at the terminal's text does. The workspace decides,
  /// because it is what knows the tab's plugins.
  var links: TerminalLinks = .none
  @AppStorage("terminalAppearance") private var appearance = "system"
  @Environment(\.colorScheme) private var scheme

  /// What the surface below will draw with, and what the far side is told.
  ///
  /// Qualified: this app's own `Palette` is the command palette, which is a
  /// different thing with the same name.
  private var palette: TetherUI.Palette {
    TetherUI.Palette.chosen(setting: appearance, scheme: scheme)
  }

  var body: some View {
    ZStack {
      Theme.terminal
      switch tab.stage {
      case .connecting, .asking:
        ProgressView()
      case .connected:
        terminal
      case .failed(let reason):
        ContentUnavailableView(
          "Could Not Connect",
          systemImage: "network.slash",
          description: Text(reason))
      case .ended(let reason):
        if let reason, !reason.isEmpty {
          ContentUnavailableView(
            "Session Ended",
            systemImage: "stop.circle",
            description: Text(reason))
        } else {
          ContentUnavailableView("Session Ended", systemImage: "stop.circle")
        }
      }
    }
    // The far side is told what this window draws with, and told again when
    // that changes: a program asks once, at the start, and paints itself for
    // the answer it got.
    .task(id: palette) { tab.use(palette: palette.remoteForm) }
  }

  @ViewBuilder
  private var terminal: some View {
    if let frame = tab.frame {
      TerminalSurface(
        frame: frame,
        onInput: { tab.send($0) },
        onResize: { tab.resize(columns: $0, rows: $1) },
        onScroll: { tab.scroll($0) },
        links: links)
    }
  }
}
