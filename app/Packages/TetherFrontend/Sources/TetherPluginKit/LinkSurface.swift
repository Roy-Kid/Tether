import SwiftUI
import Tether
import TetherUI

extension TerminalLinks {
  /// A surface's link handling, answered by `actions`: what the host's own
  /// terminal and a plugin's panes both use, so pointing means the same
  /// thing wherever the terminal is drawn.
  @MainActor
  public init(
    find: @escaping (UInt16, UInt16) -> TerminalLink?,
    actions: @escaping (TerminalLink) -> LinkActions?
  ) {
    self.init(
      find: find,
      open: { link in actions(link)?.open?() },
      menu: { link in
        guard let offered = actions(link), !offered.commands.isEmpty else { return nil }
        return LinkMenu(
          items: offered.commands.map { command in
            LinkMenu.Item(title: command.title, symbol: command.symbol, action: command.action)
          },
          preview: offered.preview)
      },
      exists: { link in
        guard let check = actions(link)?.exists else { return actions(link) != nil }
        return await check()
      })
  }
}

extension LinkActions {
  /// Several plugins' offers as one: the first to open or preview wins, the
  /// menu has everything, and a link is there if any of them finds it.
  @MainActor
  public static func combining(_ offers: [LinkActions]) -> LinkActions? {
    guard !offers.isEmpty else { return nil }
    let checks: [@MainActor () async -> Bool] = offers.compactMap(\.exists)
    var exists: (@MainActor () async -> Bool)?
    if !checks.isEmpty {
      exists = {
        for check in checks where await check() { return true }
        return false
      }
    }
    return LinkActions(
      open: offers.lazy.compactMap(\.open).first,
      preview: offers.lazy.compactMap(\.preview).first,
      commands: offers.flatMap(\.commands),
      exists: exists)
  }
}
