import Foundation
import TetherUI

@MainActor
public protocol ConsentAsking: AnyObject {
  func ask(pluginName: String, permission: Permission) async -> Bool
}

@MainActor
public protocol HostNotifying: AnyObject {
  func notify(title: String) async
}

/// Title is the plugin name. The message is the permission token. Verbs are Allow and Cancel.
public enum ConsentPrompt {
  public static func dialog(pluginName: String, permission: Permission) -> Dialog {
    Dialog(
      title: pluginName, message: permission.rawValue,
      actions: [
        Dialog.Action("Allow", role: .confirm),
        .cancel("Cancel"),
      ])
  }
}

public enum NotifyPrompt {
  public static func dialog(title: String) -> Dialog {
    Dialog(title: title, actions: [Dialog.Action("OK", role: .confirm)])
  }
}

@MainActor
public final class DialogConsent: ConsentAsking {
  public init() {}

  public func ask(pluginName: String, permission: Permission) async -> Bool {
    let reply = await DialogPresenter.ask(ConsentPrompt.dialog(pluginName: pluginName, permission: permission))
    return reply?.role == .confirm
  }
}

@MainActor
public final class DialogNotifier: HostNotifying {
  public init() {}

  public func notify(title: String) async {
    _ = await DialogPresenter.ask(NotifyPrompt.dialog(title: title))
  }
}
