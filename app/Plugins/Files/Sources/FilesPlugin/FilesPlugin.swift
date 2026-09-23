import SwiftUI
import Tether
import TetherPluginKit

/// Files, as a tab plugin: every terminal tab carries a browser of the
/// machine its shell is running on, kept in the inspector beside it.
@MainActor
public final class FilesPlugin: TabPlugin {
  public static let id = "dev.tether.files"
  public let metadata = PluginMetadata(
    id: FilesPlugin.id, name: "Files", symbol: "folder",
    summary: "Browse, preview and move files where the shell is.")
  public let accessory = TabAccessory(symbol: "folder", name: "Files", placement: .inspector)

  public init() {}

  public func attach(to tab: TabContext) -> any TabAttachment {
    FilesTab(tab: tab)
  }

  public func settings() -> AnyView { AnyView(EmptyView()) }
}
