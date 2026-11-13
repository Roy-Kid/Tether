import SwiftUI
import Tether
import TetherUI

extension EnvironmentValues {
  /// Whether this window is the interaction's effective host: it sizes
  /// the sessions and shows the pickers. Set by each root from
  /// `WorkspaceInteraction.drivesSurface`; a lone root (previews, tests)
  /// draws with the default.
  @Entry var surfaceDrivesSize = true
  /// Whether this host presents the workspace's shared presentations
  /// (palette, host picker, inline rename): the interaction's blocking
  /// owner first, then the effective host — one at a time, never both.
  @Entry var isFrontWindow = true
  /// The window that started the app. It owns the shared presenters and
  /// publishes the input/shortcut gates the quick panel reads; additional
  /// windows leave both alone. A lone root — previews, tests — is one.
  @Entry var workspaceIsPrimary = true
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
  /// True for the quick terminal's copy of this tab: it draws whole
  /// frames (`dirtyRows: nil`) and never acknowledges damage. The main
  /// window's surface stays the one incremental consumer of the shared
  /// damage — a second acknowledger would clear rows the other has not
  /// drawn. The passive copy still sizes the session and answers the
  /// palette when its window is in front.
  var passive = false
  /// What a key on a down tab's last screen does. The workspace raises
  /// the tab's question; the quick terminal overrides this to reveal the
  /// workspace window first, which is where the question is asked.
  var onUnavailableInput: (() -> Void)?
  var onFocus: () -> Void = {}
  @AppStorage(TetherUI.Palette.colorStyleKey) private var colorStyle = TetherUI.Palette.defaultColorStyle
  @Environment(\.colorScheme) private var scheme
  @Environment(\.surfaceDrivesSize) private var drivesSize
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
    // the answer it got. Only the window in front of those showing these
    // tabs answers, so two differently themed surfaces cannot fight.
    .task(id: palette) { applyPalette() }
    // Sizing passed to this window: the session takes the size it shows here.
    .onChange(of: drivesSize) { _, drives in
      guard drives else { return }
      if let wanted { tab.resize(columns: wanted.columns, rows: wanted.rows) }
      applyPalette()
    }
  }

  /// The palette this window would answer with, told to the far side only
  /// while this window is the one in front (`isFrontWindow`).
  private func applyPalette() {
    guard drivesSize else { return }
    tab.use(palette: palette.remoteForm)
  }

  /// What the terminal last showed, dimmed and taking no input. Text can
  /// still be selected and copied: it is the record of what happened.
  @ViewBuilder
  private var snapshot: some View {
    if let frame = tab.frame {
      TerminalSurface(
        frame: frame, active: active,
        onInput: { _ in
          if let onUnavailableInput { onUnavailableInput() } else { tab.raiseProblem() }
        },
        onFocus: onFocus)
        .overlay { palette.background.opacity(0.4).allowsHitTesting(false) }
        .accessibilityValue(tab.stateName)
    }
  }

  @ViewBuilder
  private var terminal: some View {
    if let frame = tab.frame {
      TerminalSurface(
        frame: frame,
        dirtyRows: passive ? nil : tab.dirtyRows,
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
        damageEpoch: passive ? 0 : tab.damageEpoch,
        onPresented: passive ? { _ in } : { tab.acknowledgeDamage(epoch: $0) })
    }
  }
}
