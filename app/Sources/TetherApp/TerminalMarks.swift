import TetherPluginKit

/// Where every status mark the app draws is looked up: a tab's own chip, and
/// a plugin's rows through `TabContext.terminalIndicator`. Both name ttys on
/// the tab's machine, as the tab's identity names it; the registry's one
/// lookup decides between marks.
extension PluginRegistry {
  /// The tab's mark: on its shell, or on a terminal an attachment says the
  /// tab is showing.
  func indicator(on tab: SessionTab) -> PluginTabIndicator? {
    guard let shell = tab.pluginTerminalIdentity else { return nil }
    let shown = tab.attachments.flatMap { $0.attachment.shownTerminals }
    return indicator(on: tab, terminals: [shell.terminal] + shown)
  }

  /// The mark on any of these ttys of the tab's machine. Nil until the shell
  /// has said which machine that is.
  func indicator(on tab: SessionTab, terminals: [String]) -> PluginTabIndicator? {
    // Marks live on the reporting plugin, which a view drawing them never
    // holds. Reading the epoch is what makes that view draw again.
    _ = tabIndicatorEpoch
    guard let host = tab.pluginTerminalIdentity?.host, !terminals.isEmpty else { return nil }
    return tabIndicator(onAnyOf: terminals.map { PluginTerminalIdentity(host: host, terminal: $0) })
  }
}

/// What sits in front of a terminal's name, on the strip and on a split pane.
///
/// A plugin's `tabSymbols` entry wins, then the attachment that is standing
/// in for the shell. Otherwise it is a terminal: the same mark for every
/// host, because a local shell is a host like any other. Reading the epoch
/// is what draws a new symbol.
@MainActor
func terminalChipSymbol(for tab: SessionTab, registry: PluginRegistry?) -> String {
  _ = registry?.tabIndicatorEpoch
  if tab.handoff, !tab.isLive { return "arrow.left.arrow.right" }
  if let identity = tab.pluginTerminalIdentity,
    let symbol = registry?.tabSymbol(for: identity), !symbol.isEmpty
  {
    return symbol
  }
  if let shown = tab.shown, !shown.symbol.isEmpty { return shown.symbol }
  return "terminal"
}
