import Foundation
import Tether
import TetherUI

/// Something a login needs a person to decide.
///
/// Asked from the middle of a handshake, which is parked until the answer
/// comes back. Each has exactly one dialog, drawn by ``DialogPresenter`` like
/// every other in the app — the handshake is not a special case on screen,
/// only in when it asks.
enum HandshakeQuestion {
  /// A host this device has never seen. A key that *changed* is never asked
  /// about here: replacing a pin is a Settings operation, not a tap.
  case trust(HostIdentity)
  /// A managed profile's approval, before any credential is used.
  case confirmation(title: String, detail: String)
  /// One keyboard-interactive round: the server's own prompts and words, and
  /// a line of this app's when the server is asking again.
  case prompts([AuthPrompt], instruction: String, notice: String?)
  /// A private key's passphrase, once the server said it would take the key.
  /// Named by what this device calls the key; the fingerprint says which
  /// one it is, and the notice replaces it when a passphrase was wrong.
  case passphrase(key: String, fingerprint: String?, notice: String?)

  var dialog: Dialog {
    switch self {
    case .trust(let host):
      Dialog(title: "Unrecognised host", message: host.fingerprint, actions: [.cancel("Reject"), Dialog.Action("Trust")])
    case .confirmation(let title, let detail):
      Dialog(title: title, message: detail, actions: [.cancel(), Dialog.Action("Approve")])
    case .prompts(let prompts, let instruction, let notice):
      Self.dialog(prompts, instruction: instruction, notice: notice)
    case .passphrase(let key, let fingerprint, let notice):
      Dialog(
        title: "Unlock \(key)", message: notice ?? fingerprint,
        fields: [Dialog.Field("Passphrase", kind: .password)],
        actions: [.cancel(), Dialog.Action("Unlock")])
    }
  }

  /// What goes back to the handshake. `nil` is a no.
  func answers(from reply: DialogReply?) -> [String]? {
    guard let reply, reply.isAffirmative else { return nil }
    return reply.values
  }

  /// The first prompt is the title; every other one labels its own field.
  /// The server's instruction is its own wording about what to use, and is
  /// shown rather than parsed — unless the notice has something to say.
  private static func dialog(_ prompts: [AuthPrompt], instruction: String, notice: String?) -> Dialog {
    let title = prompts.first.map(promptDialogTitle) ?? "Continue"
    let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = prompts.map { prompt in
      let label = promptDialogTitle(prompt)
      return Dialog.Field(label == title ? "" : label, kind: fieldKind(prompt))
    }
    return Dialog(
      title: title, message: notice ?? (words == title ? nil : words), fields: fields,
      actions: [.cancel(), Dialog.Action("Continue")])
  }

  /// Hidden whenever the server says so. A password is filled from saved
  /// passwords; anything else hidden is offered the code the system just
  /// received — it is a code more often than not, and a wrong suggestion
  /// costs nothing.
  private static func fieldKind(_ prompt: AuthPrompt) -> Dialog.Field.Kind {
    if prompt.echo { return .text }
    return isAccountPasswordPrompt(prompt) ? .password : .code
  }
}

/// Whether a prompt asks for the account password — and so may be answered
/// with the one a person already gave. Never a one-time code: a saved
/// password sent where a code was wanted is a refused login and a password
/// shown to whatever asked. Never a new one either: an expired password's
/// `New password:` answered with the old one is a change nobody made.
func isAccountPasswordPrompt(_ prompt: AuthPrompt) -> Bool {
  guard !prompt.echo else { return false }
  let folded = prompt.text.lowercased()
  if folded.contains("one-time") || folded.contains("verification")
    || folded.contains("otp") || folded.contains("token")
    || folded.contains("passcode") || folded.contains("authenticator")
    || folded.contains("challenge") || folded.contains("re-enter")
  {
    return false
  }
  let words = Set(folded.split { !$0.isLetter }.map(String.init))
  guard words.isDisjoint(with: ["new", "retype", "again", "confirm", "verify", "repeat", "reenter"]) else {
    return false
  }
  let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
    .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed == "password" || trimmed.hasPrefix("password ")
    || trimmed.hasSuffix(" password")
}

/// The server's prompt, without a trailing colon, for a dialog title.
func promptDialogTitle(_ prompt: AuthPrompt) -> String {
  var text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
  while text.hasSuffix(":") || text.hasSuffix("：") {
    text.removeLast()
  }
  text = text.trimmingCharacters(in: .whitespaces)
  return text.isEmpty ? "Continue" : text
}
