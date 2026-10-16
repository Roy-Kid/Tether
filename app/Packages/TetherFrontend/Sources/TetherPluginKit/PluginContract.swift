import Foundation
import TetherUI

/// The tab a plugin was opened against, as data. A page can read this.
/// The lease itself stays on ``PluginContext`` for an in-process plugin.
public struct PluginEnvironment: Sendable, Equatable, Codable {
  public var hostID: UUID?
  public var hostLabel: String
  public var shellLabel: String
  public var connected: Bool

  public init(hostID: UUID?, hostLabel: String, shellLabel: String, connected: Bool) {
    self.hostID = hostID
    self.hostLabel = hostLabel
    self.shellLabel = shellLabel
    self.connected = connected
  }

  public static let none = PluginEnvironment(hostID: nil, hostLabel: "", shellLabel: "", connected: false)
}

public struct PluginField: Sendable, Equatable {
  public var label: String
  public var initial: String
  public var secure: Bool

  public init(label: String, initial: String = "", secure: Bool = false) {
    self.label = label
    self.initial = initial
    self.secure = secure
  }
}

public struct PluginAction: Sendable, Equatable, Identifiable {
  public var id: String
  public var title: String
  public var destructive: Bool

  public init(id: String, title: String, destructive: Bool = false) {
    self.id = id
    self.title = title
    self.destructive = destructive
  }

  public static func confirm(_ title: String, destructive: Bool = false) -> PluginAction {
    PluginAction(id: "confirm", title: title, destructive: destructive)
  }
}

/// A question a plugin asks the host to show. The host draws it.
public struct PluginPrompt: Sendable, Equatable {
  public var title: String
  public var message: String?
  public var field: PluginField?
  public var actions: [PluginAction]
  public var cancel: String

  public init(
    title: String, message: String? = nil, field: PluginField? = nil, actions: [PluginAction],
    cancel: String = "Cancel"
  ) {
    self.title = title
    self.message = message
    self.field = field
    self.actions = actions
    self.cancel = cancel
  }

  public static func confirm(
    _ title: String, message: String? = nil, verb: String, destructive: Bool = false, cancel: String = "Cancel"
  ) -> PluginPrompt {
    PluginPrompt(title: title, message: message, actions: [.confirm(verb, destructive: destructive)], cancel: cancel)
  }

  public static func input(
    _ title: String, field: String, initial: String = "", verb: String, secure: Bool = false
  ) -> PluginPrompt {
    PluginPrompt(
      title: title, field: PluginField(label: field, initial: initial, secure: secure),
      actions: [.confirm(verb)])
  }

  public static func choose(_ title: String, actions: [PluginAction], cancel: String) -> PluginPrompt {
    PluginPrompt(title: title, actions: actions, cancel: cancel)
  }
}

public struct PluginAnswer: Sendable, Equatable {
  public var action: String?
  public var value: String

  public init(action: String?, value: String = "") {
    self.action = action
    self.value = value
  }

  public var confirmed: Bool { action == "confirm" }
  public static let cancelled = PluginAnswer(action: nil)
}

public enum PluginServiceError: Error, Equatable {
  case unavailable
  case denied
  case malformed
}

/// What one plugin may ask the host to do. Native code and a web page share it.
@MainActor
public protocol PluginServing: AnyObject {
  func notify(title: String, body: String) async
  func ask(_ prompt: PluginPrompt) async -> PluginAnswer
  func storageGet(pluginID: String, pluginName: String, key: String) async throws -> String?
  func storageSet(pluginID: String, pluginName: String, key: String, value: String) async throws
  func readDocument(pluginID: String, handle: UUID) async throws -> Data
  func openStream(pluginID: String, url: URL) async throws -> UUID
  func closeStream(pluginID: String, id: UUID) async
  func reportStatus(pluginID: String, item: PluginStatusBarItem)
}

/// The host installs one of these. Plugins call ``PluginServices`` and reach it.
@MainActor
public enum PluginGateway {
  public static weak var current: (any PluginServing)?
}

/// The host services on a ``PluginContext``. Methods match the web calls.
@MainActor
public struct PluginServices {
  public var pluginID: String
  public var pluginName: String

  public init(pluginID: String = "", pluginName: String = "") {
    self.pluginID = pluginID
    self.pluginName = pluginName
  }

  public func notify(title: String, body: String = "") async {
    await PluginGateway.current?.notify(title: title, body: body)
  }

  public func ask(_ prompt: PluginPrompt) async -> PluginAnswer {
    if let current = PluginGateway.current { return await current.ask(prompt) }
    return await PluginDialogs.ask(prompt)
  }

  public func storageGet(_ key: String) async throws -> String? {
    guard let current = PluginGateway.current else { throw PluginServiceError.unavailable }
    return try await current.storageGet(pluginID: pluginID, pluginName: pluginName, key: key)
  }

  public func storageSet(_ key: String, _ value: String) async throws {
    guard let current = PluginGateway.current else { throw PluginServiceError.unavailable }
    try await current.storageSet(pluginID: pluginID, pluginName: pluginName, key: key, value: value)
  }

  public func readDocument(_ handle: UUID) async throws -> Data {
    guard let current = PluginGateway.current else { throw PluginServiceError.unavailable }
    return try await current.readDocument(pluginID: pluginID, handle: handle)
  }

  public func openStream(_ url: URL) async throws -> UUID {
    guard let current = PluginGateway.current else { throw PluginServiceError.unavailable }
    return try await current.openStream(pluginID: pluginID, url: url)
  }

  public func closeStream(_ id: UUID) async {
    await PluginGateway.current?.closeStream(pluginID: pluginID, id: id)
  }

  public func reportStatus(_ item: PluginStatusBarItem) {
    PluginGateway.current?.reportStatus(pluginID: pluginID, item: item)
  }
}

/// A prompt as the one dialog the host already shows.
public struct PluginDialog {
  public let dialog: Dialog
  /// Action id for each dialog button, in order. Nil is cancel.
  public let ids: [String?]

  public init(_ prompt: PluginPrompt) {
    if let field = prompt.field {
      dialog = Dialog.input(
        prompt.title,
        field: Dialog.Field(field.label, kind: field.secure ? .password : .text, initial: field.initial),
        verb: prompt.actions.first?.title ?? "OK", perform: { _ in })
      ids = [nil, prompt.actions.first?.id]
      return
    }
    if prompt.actions.count == 1, let action = prompt.actions.first {
      dialog = Dialog.confirm(
        prompt.title, message: prompt.message, verb: action.title,
        role: action.destructive ? .destructive : .confirm, perform: {})
      ids = [nil, action.id]
      return
    }
    var buttons = prompt.actions.map {
      Dialog.Action($0.title, role: $0.destructive ? .destructive : .confirm)
    }
    buttons.append(.cancel(prompt.cancel))
    dialog = Dialog(title: prompt.title, message: prompt.message, actions: buttons)
    ids = prompt.actions.map(\.id) + [nil]
  }

  public func answer(_ reply: DialogReply?) -> PluginAnswer {
    guard let reply, ids.indices.contains(reply.action) else { return .cancelled }
    return PluginAnswer(action: ids[reply.action], value: reply.values.first ?? "")
  }
}

@MainActor
public enum PluginDialogs {
  public static func ask(_ prompt: PluginPrompt) async -> PluginAnswer {
    let presented = PluginDialog(prompt)
    return presented.answer(await DialogPresenter.ask(presented.dialog))
  }
}
