import Foundation
import TetherUI

@MainActor
public protocol ConsentAsking: AnyObject {
  func ask(pluginName: String, permission: Permission) async -> Bool
  func ask(pluginName: String, permission: Permission, resources: [String]) async -> Bool
}

extension ConsentAsking {
  public func ask(pluginName: String, permission: Permission, resources: [String]) async -> Bool {
    await ask(pluginName: pluginName, permission: permission)
  }
}

/// Network installation prompts explain scope and persistence; document grants stay per use.
public enum ConsentPrompt {
  public static func dialog(pluginName: String, permission: Permission, resources: [String] = []) -> Dialog {
    let network = permission == .network
    let localOnly = !resources.isEmpty && resources.allSatisfy { text in
      guard let host = URL(string: text)?.host else { return false }
      return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
    return Dialog(
      title: network ? "Install \(pluginName)?" : pluginName,
      message: network ? "Allow \(pluginName) to connect to \(localOnly ? "a service on this device" : "the listed network services")? Only the addresses below are allowed. This approval is saved for this installation. Restarting Tether or reconnecting will not ask again." : permission.rawValue,

      actions: [
        Dialog.Action(network ? "Allow and Install" : "Allow", role: .confirm),
        .cancel("Cancel"),
      ])
  }
}

@MainActor
public final class DialogConsent: ConsentAsking {
  public init() {}

  public func ask(pluginName: String, permission: Permission, resources: [String]) async -> Bool {
    var dialog = ConsentPrompt.dialog(pluginName: pluginName, permission: permission, resources: resources)
    if !resources.isEmpty { dialog.detail = "Allowed connection addresses:\n" + resources.joined(separator: "\n") }
    let reply = await DialogPresenter.ask(dialog)
    return reply?.role == .confirm
  }

  public func ask(pluginName: String, permission: Permission) async -> Bool {
    let reply = await DialogPresenter.ask(ConsentPrompt.dialog(pluginName: pluginName, permission: permission))
    return reply?.role == .confirm
  }
}
