import Foundation

/// Something that went wrong on a tab, told to the person once — as a
/// dialog that names the host and the reason, not as a page left in the tab.
struct SessionProblem: Hashable {
  enum Kind: Hashable {
    /// The login or the shell never came up.
    case couldNotConnect
    /// It was up, and the connection went away. A shell that *exits*, even
    /// with a failure, is someone's `exit` — told in the tab, not by a dialog.
    case lost
    case history
  }

  let id = UUID()
  let kind: Kind
  let reason: String
  /// The server turned the credentials down. Trying again means asking the
  /// person, not sending what was just refused.
  var refusedLogin = false
}

/// A password a person typed that has just worked, and is not the one this
/// device keeps. Offered to be kept only once it has been proven — keeping
/// whatever was typed is how a wrong password gets sent on every login.
struct PasswordOffer: Hashable {
  let id = UUID()
  let password: String
}

/// A tab's problem, with what the dialog needs to name it.
struct TabProblem: Hashable {
  let tab: SessionTab.ID
  let host: Host
  let problem: SessionProblem
}

/// A tab's password offer, with what the dialog needs to name it.
struct TabPasswordOffer: Hashable {
  let tab: SessionTab.ID
  let host: Host
  let offer: PasswordOffer
}

/// A password asked for before dialling: for a new tab, or for a failed one
/// being tried again.
struct ConnectRequest: Hashable {
  let id = UUID()
  let host: Host
  var retrying: SessionTab.ID?
  var restoring: UUID?
}

extension Host {
  /// What a dialog calls this host.
  var displayName: String {
    let name = label.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? hostname : name
  }
}
