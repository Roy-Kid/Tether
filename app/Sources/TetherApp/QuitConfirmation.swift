import TetherUI

/// Whether quitting asks first (spec §6: quitting must not bypass the
/// live-shell confirmation).
///
/// Only a live terminal is worth a question: quitting stops its shell, or
/// drops its connection, and that cannot be undone. Nothing live, nothing
/// asked — a Mac app that questions every ⌘Q teaches people to stop reading.
enum QuitConfirmation {
  enum Decision: Equatable {
    case quit
    case ask
  }

  static func decision(live: Int) -> Decision {
    live > 0 ? .ask : .quit
  }

  /// A title and a verb, and one line for what "Quit" does not say: how
  /// many shells stop with it. Return does not quit; ⌘Q a second time does,
  /// as ⌘W twice closes a live terminal.
  static func dialog(live: Int) -> Dialog {
    Dialog.confirm(
      "Quit Tether?", message: live == 1 ? "1 terminal will stop." : "\(live) terminals will stop.",
      verb: "Quit", role: .destructive, shortcuts: [.command("q")], perform: {})
  }
}

#if os(macOS)
  import AppKit

  extension TabSet {
    var liveTerminalCount: Int { tabs.filter(\.isLive).count }
  }

  /// The question asked from `applicationShouldTerminate`, answered later.
  /// Every way of quitting arrives there: ⌘Q, the Dock, logging out.
  @MainActor
  final class QuitGate {
    private var asking: Task<Void, Never>?

    func shouldTerminate(_ app: NSApplication, tabs: TabSet?) -> NSApplication.TerminateReply {
      shouldTerminate(app, live: tabs?.liveTerminalCount ?? 0)
    }

    func shouldTerminate(_ app: NSApplication, live: Int) -> NSApplication.TerminateReply {
      guard QuitConfirmation.decision(live: live) == .ask else { return .terminateNow }
      // Already asking: this second request is the same question.
      guard asking == nil else { return .terminateCancel }
      asking = Task { [weak self] in
        let reply = await DialogPresenter.ask(QuitConfirmation.dialog(live: live))
        self?.asking = nil
        app.reply(toApplicationShouldTerminate: reply?.isAffirmative == true)
      }
      return .terminateLater
    }
  }
#endif
