import SwiftUI
import Tether
import TetherUI

extension EnvironmentValues {
  /// Whether this window is in front of those showing its tabs
  /// (`TabSet.isFront`). Two windows can show the same tabs at different
  /// sizes; the one in front sizes the sessions and shows the pickers.
  @Entry var isFrontWindow = true
}

/// A size the surface asked for.
private struct GridSize: Equatable {
  let columns: UInt16
  let rows: UInt16
}

/// One tab's contents.
struct SessionView: View {
  let tab: SessionTab
  /// What pointing at the terminal's text does. The workspace decides,
  /// because it is what knows the tab's plugins.
  var links: TerminalLinks = .none
  var menuItems: [TerminalMenuItem] = []
  var active = true
  var onFocus: () -> Void = {}
  @AppStorage(TetherUI.Palette.colorStyleKey) private var colorStyle = TetherUI.Palette.defaultColorStyle
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isFrontWindow) private var drivesSize
  /// What this window's surface would size the session to. Kept while
  /// another window sizes it, and applied when this one does again.
  @State private var wanted: GridSize?

  /// What the surface below will draw with, and what the far side is told.
  /// The window already followed the system theme; the grid follows that.
  ///
  /// Qualified: this app's own `Palette` is the command palette, which is a
  /// different thing with the same name.
  private var palette: TetherUI.Palette {
    TetherUI.Palette.chosen(setting: "system", scheme: scheme, style: colorStyle)
  }

  var body: some View {
    ZStack {
      Color.clear
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
    // The far side is told what this window draws with, and told again when
    // that changes: a program asks once, at the start, and paints itself for
    // the answer it got.
    .task(id: palette) { tab.use(palette: palette.remoteForm) }
    // Sizing passed to this window: the session takes the size it shows here.
    .onChange(of: drivesSize) { _, drives in
      guard drives, let wanted else { return }
      tab.resize(columns: wanted.columns, rows: wanted.rows)
    }
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
        onResize: { columns, rows in
          wanted = GridSize(columns: columns, rows: rows)
          if drivesSize { tab.resize(columns: columns, rows: rows) }
        },
        onFocus: onFocus,
        onScroll: { tab.scroll($0) },
        onClaimWheel: { tab.claimWheel($0, column: $1, row: $2) },
        links: links,
        damageEpoch: tab.damageEpoch,
        onPresented: { tab.acknowledgeDamage(epoch: $0) })
    }
  }
}
