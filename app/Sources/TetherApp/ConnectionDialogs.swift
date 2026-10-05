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
  static func problem(
    _ report: TabProblem, close: @escaping @MainActor () -> Void, again: @escaping @MainActor () -> Void
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
    return Dialog(
      title: title, message: report.problem.reason,
      actions: [.cancel("Close", perform: close), Dialog.Action(verb) { _ in again() }])
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

/// Where the window asks them.
struct ConnectionDialogs: ViewModifier {
  @Bindable var tabs: TabSet
  let connecting: ConnectRequest?
  let connect: (ConnectRequest, String) -> Void
  let cancelConnect: (ConnectRequest) -> Void
  let retry: (TabProblem) -> Void
  let keep: (TabPasswordOffer) -> Void
  /// Whether the host keeps a password now — the offer is worded for that.
  let remembers: (Host) -> Bool

  func body(content: Content) -> some View {
    content
      .dialog(for: connecting) { request in
        ConnectionDialog.password(
          request, connect: { connect(request, $0) }, cancel: { cancelConnect(request) })
      }
      .dialog(for: tabs.problem) { report in
        if report.problem.kind == .history {
          Dialog(title: "Could Not Save Session History", message: report.problem.reason,
            actions: [Dialog.Action("OK") { _ in tabs.tabs.first { $0.id == report.tab }?.acknowledge() }])
        } else {
          ConnectionDialog.problem(report, close: { tabs.close(report.tab) }, again: { retry(report) })
        }
      }
      .dialog(for: tabs.historyProblem) { problem in
        Dialog(title: "Could Not Save Session History", message: problem,
          actions: [Dialog.Action("OK") { _ in tabs.historyProblem = nil }])
      }
      .dialog(for: tabs.passwordOffer) { offer in
        ConnectionDialog.keep(
          offer, replacing: remembers(offer.host), keep: { keep(offer) },
          decline: { tabs.answer(offer, kept: false) })
      }
  }
}
