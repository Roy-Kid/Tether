import SwiftUI
import Tether
import TetherUI

/// One tab's contents.
struct SessionView: View {
  let tab: SessionTab
  /// What pointing at the terminal's text does. The workspace decides,
  /// because it is what knows the tab's plugins.
  var links: TerminalLinks = .none
  var menuItems: [TerminalMenuItem] = []
  var active = true
  var onFocus: () -> Void = {}
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
      palette.background
      switch tab.stage {
      case .connecting, .asking:
        // A reconnect keeps the screen it is trying to bring back.
        snapshot
        ProgressView()
      case .connected:
        terminal
      case .failed, .lost:
        // The last screen, read only. The tab and the status bar say it is
        // down; typing here is acting on it, and that is when it asks.
        snapshot
      case .ended(let reason):
        QuietMark("Session Ended", systemImage: "stop.circle", detail: reason)
      }
    }
    // Marks and the spinner follow the terminal, so a dark grid in a light
    // window still has light chrome on it.
    .terminalContextMenu(menuItems)
    .environment(\.colorScheme, palette == .dark ? .dark : .light)
    // The far side is told what this window draws with, and told again when
    // that changes: a program asks once, at the start, and paints itself for
    // the answer it got.
    .task(id: palette) { tab.use(palette: palette.remoteForm) }
  }

  /// What the terminal last showed, dimmed and taking no input. Text can
  /// still be selected and copied: it is the record of what happened.
  @ViewBuilder
  private var snapshot: some View {
    if let frame = tab.frame {
      TerminalSurface(frame: frame, active: active, onInput: { _ in tab.raiseProblem() }, onFocus: onFocus)
        .overlay { palette.background.opacity(0.4).allowsHitTesting(false) }
        .accessibilityValue(tab.stateName)
    }
  }

  @ViewBuilder
  private var terminal: some View {
    if let frame = tab.frame {
      TerminalSurface(
        frame: frame,
        dirtyRows: tab.dirtyRows,
        active: active,
        onInput: { tab.send($0) },
        onResize: { tab.resize(columns: $0, rows: $1) },
        onFocus: onFocus,
        onScroll: { tab.scroll($0) },
        onClaimWheel: { tab.claimWheel($0, column: $1, row: $2) },
        links: links)
    }
  }
}
