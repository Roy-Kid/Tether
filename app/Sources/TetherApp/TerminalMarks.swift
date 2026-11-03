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
