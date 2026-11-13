import SwiftUI
import TetherUI

/// The dialogs a connection puts to a person outside the handshake itself:
/// the password asked before dialling, what went wrong, and whether to keep
/// a password that worked.
///
/// Every one names its host — two tabs can be connecting at once, and a
/// question or a failure that does not say where is one a person can answer
/// wrongly.
enum ConnectionDialog {
  /// A password for a host that has no key and nothing saved.
  static func password(
    _ request: ConnectRequest, connect: @escaping @MainActor (String) -> Void,
    cancel: @escaping @MainActor () -> Void
  ) -> Dialog {
    Dialog(
      title: request.host.displayName, message: request.host.address,
      fields: [Dialog.Field("Password", kind: .password)],
      actions: [.cancel(perform: cancel), Dialog.Action("Connect") { connect($0.first ?? "") }])
  }

  /// What went wrong, and the two things to do about it.
  ///
  /// Escape never costs anything: when the tab still holds a screen — a
  /// connection that was lost, or a reconnect that failed — the way out is
  /// "Not Now", which leaves the tab as it is. Only a tab that never showed
  /// anything closes on the way out.
  static func problem(
    _ report: TabProblem, close: @escaping @MainActor () -> Void,
    setAside: @escaping @MainActor () -> Void = {}, again: @escaping @MainActor () -> Void
  ) -> Dialog {
    let name = report.host.displayName
    let title: String
    let verb: String
    switch report.problem.kind {
    case .couldNotConnect:
      title = "Could Not Connect to \(name)"
      verb = "Retry"
    case .history:
      title = "Could Not Save History for \(name)"
      verb = "OK"
    case .lost:
      title = "Connection to \(name) Lost"
      verb = report.host.isLocal ? "Restart" : "Reconnect"
    }
    let keeps = report.keepsScreen || report.problem.kind == .lost
    return Dialog(
      title: title, message: report.problem.reason,
      actions: [keeps ? .cancel("Not Now", perform: setAside) : .cancel("Close", perform: close),
                Dialog.Action(verb) { _ in again() }])
  }

  /// A password that just worked, offered to be kept — or to replace the
  /// saved one the server refused.
  static func keep(
    _ offer: TabPasswordOffer, replacing: Bool, keep: @escaping @MainActor () -> Void,
    decline: @escaping @MainActor () -> Void
  ) -> Dialog {
    let name = offer.host.displayName
    return Dialog(
      title: replacing ? "Update the saved password for \(name)?" : "Save the password for \(name)?",
      actions: [.cancel("Not Now", perform: decline), Dialog.Action(replacing ? "Update" : "Save") { _ in keep() }])
  }
}
