import Foundation

/// A question put to a person: a title, at most one line more, the fields
/// it needs typed, and the verbs that answer it (law: app-ui-chrome).
/// `detail` is data shown with the question — a diff — never a second sentence.
///
/// One description for every dialog the app and its plugins show, whoever is
/// asking — a view whose state holds a pending question, or a handshake
/// parked until somebody answers. All of them reach the screen through
/// ``DialogPresenter``: one queue, one surface per platform, and one rule
/// about what sits on top of what. A dialog is data; nothing here knows how
/// it is drawn.
public struct Dialog: Identifiable {
  public let id = UUID()
  public var title: String
  /// Only when the consequence is not already the button.
  public var message: String?
  /// Data that belongs with the question, such as a diff. Not a sentence.
  public var detail: String?
  public var fields: [Field]
  /// In reading order. Return chooses the default action; Escape cancels.
  public var actions: [Action]

  public init(title: String, message: String? = nil, detail: String? = nil, fields: [Field] = [], actions: [Action]) {
    self.title = title
    self.message = message.flatMap { $0.isEmpty ? nil : $0 }
    self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
    self.fields = fields
    self.actions = actions
  }

  /// Something to type.
  public struct Field: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      /// Shown as typed.
      case text
      /// Hidden as typed, and filled from the person's saved passwords.
      case password
      /// Hidden as typed, and filled from a code the system just received.
      case code
    }

    public var placeholder: String
    public var kind: Kind
    public var initial: String

    public init(_ placeholder: String, kind: Kind = .text, initial: String = "") {
      self.placeholder = placeholder
      self.kind = kind
      self.initial = initial
    }

    public var isSecure: Bool { kind != .text }
  }

  /// A verb, and what it does with what was typed.
  public struct Action {
    public enum Role: Equatable, Sendable {
      case confirm
      case destructive
      case cancel
    }

    /// Explicit Mac keyboard confirmation for a particular action. Destructive
    /// actions have no Return shortcut unless the caller opts in.
    public enum Shortcut: Equatable, Sendable {
      case enter
      case command(String)
    }

    public var title: String
    public var role: Role
    public var shortcuts: [Shortcut]
    /// Runs on the main actor with one value per field, before the reply is
    /// handed back to whoever asked.
    public var perform: @MainActor ([String]) -> Void

    public init(_ title: String, role: Role = .confirm, shortcuts: [Shortcut] = [],
      perform: @escaping @MainActor ([String]) -> Void = { _ in }) {
      self.title = title
      self.role = role
      self.shortcuts = shortcuts
      self.perform = perform
    }

    public static func cancel(_ title: String = "Cancel", perform: @escaping @MainActor () -> Void = {}) -> Action {
      Action(title, role: .cancel) { _ in perform() }
    }
  }

  /// A yes-or-no question: the verb, and Cancel.
  public static func confirm(
    _ title: String, message: String? = nil, detail: String? = nil, verb: String,
    role: Action.Role = .confirm, shortcuts: [Action.Shortcut] = [],
    cancel: @escaping @MainActor () -> Void = {}, perform: @escaping @MainActor () -> Void
  ) -> Dialog {
    Dialog(
      title: title, message: message, detail: detail,
      actions: [.cancel(perform: cancel), Action(verb, role: role, shortcuts: shortcuts) { _ in perform() }])
  }

  /// Something that has already happened, and one button to say so.
  public static func notice(
    _ title: String, message: String? = nil, dismiss: @escaping @MainActor () -> Void = {}
  ) -> Dialog {
    Dialog(title: title, message: message, actions: [Action("OK", role: .cancel) { _ in dismiss() }])
  }

  /// One field and a verb, as a rename is.
  public static func input(
    _ title: String, field: Field, verb: String,
    cancel: @escaping @MainActor () -> Void = {}, perform: @escaping @MainActor (String) -> Void
  ) -> Dialog {
    Dialog(
      title: title, fields: [field],
      actions: [.cancel(perform: cancel), Action(verb) { perform($0.first ?? "") }])
  }

  /// An explicit Enter action, or the first ordinary confirmation.
  public var defaultAction: Int? {
    actions.firstIndex { $0.shortcuts.contains(.enter) } ?? actions.firstIndex { $0.role == .confirm }
  }

  /// The action Escape performs.
  public var cancelAction: Int? {
    actions.firstIndex { $0.role == .cancel }
  }
}

/// What a person chose.
public struct DialogReply: Equatable, Sendable {
  /// Index into the dialog's `actions`.
  public let action: Int
  public let role: Dialog.Action.Role
  /// One per field, in order.
  public let values: [String]

  public init(action: Int, role: Dialog.Action.Role, values: [String]) {
    self.action = action
    self.role = role
    self.values = values
  }

  /// Answered with anything but Cancel.
  public var isAffirmative: Bool { role != .cancel }
}
