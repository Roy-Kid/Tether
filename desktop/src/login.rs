//! The questions a login asks, worded as the Mac app words them
//! (`HandshakeQuestion`, `ConnectionDialog`). A title is the action; the
//! verb is the button; a prompt the server sent is shown, never parsed for
//! meaning beyond whether it asks for the account password.

use crate::dialog::{Action, Dialog, Field, FieldKind};

/// One question from a keyboard-interactive round.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prompt {
    pub text: String,
    pub echo: bool,
}

/// A new host key: named by the address it was offered for, and shown the
/// way an administrator would publish it.
pub fn trust(host: &str, port: u16, algorithm: &str, fingerprint: &str) -> Dialog {
    let place = if port == 22 { host.to_owned() } else { format!("{host}:{port}") };
    Dialog::new(
        format!("Trust {place}?"),
        Some(format!("{algorithm}\n{fingerprint}")),
        Vec::new(),
        vec![Action::cancel("Reject"), Action::confirm("Trust")],
    )
}

/// A key's passphrase, asked once the server said it would take the key.
pub fn passphrase(key: &str, fingerprint: Option<&str>, attempt: u32) -> Dialog {
    let notice = (attempt > 1).then(|| "The passphrase was not accepted.".to_owned());
    Dialog::new(
        format!("Unlock {key}"),
        notice.or_else(|| fingerprint.map(str::to_owned)),
        vec![Field::new("Passphrase", FieldKind::Password)],
        vec![Action::cancel("Cancel"), Action::confirm("Unlock")],
    )
}

/// A keyboard-interactive round. The first prompt is the title; every
/// other one labels its own field. The instruction is shown when it adds
/// something the title does not say.
pub fn prompts(prompts: &[Prompt], instruction: &str, notice: Option<&str>) -> Dialog {
    let title = prompts.first().map_or_else(|| "Continue".to_owned(), title_of);
    let words = instruction.trim();
    let fields = prompts
        .iter()
        .map(|prompt| {
            let label = title_of(prompt);
            Field::new(if label == title { String::new() } else { label }, kind_of(prompt))
        })
        .collect();
    let message = notice
        .map(str::to_owned)
        .or_else(|| (!words.is_empty() && words != title).then(|| words.to_owned()));
    Dialog::new(title, message, fields, vec![Action::cancel("Cancel"), Action::confirm("Continue")])
}

/// A password for a host with no key and nothing saved.
pub fn password(display: &str, address: &str) -> Dialog {
    Dialog::new(
        display,
        Some(address.to_owned()),
        vec![Field::new("Password", FieldKind::Password)],
        vec![Action::cancel("Cancel"), Action::confirm("Connect")],
    )
}

/// What went wrong while connecting, and the way back in. A tab that never
/// showed a screen closes on the way out; one that did is set aside.
pub fn could_not_connect(display: &str, reason: &str, keeps_screen: bool) -> Dialog {
    Dialog::new(
        format!("Could Not Connect to {display}"),
        Some(reason.to_owned()),
        Vec::new(),
        vec![
            Action::cancel(if keeps_screen { "Not Now" } else { "Close" }),
            Action::confirm("Retry"),
        ],
    )
}

/// A connection that was up and went away.
pub fn lost(display: &str, reason: &str, local: bool) -> Dialog {
    Dialog::new(
        format!("Connection to {display} Lost"),
        Some(reason.to_owned()),
        Vec::new(),
        vec![
            Action::cancel("Not Now"),
            Action::confirm(if local { "Restart" } else { "Reconnect" }),
        ],
    )
}

/// Why a connection failed, in the words a person is shown (the Swift
/// facade's `errorDescription`). `keys` names the credentials offered, by
/// position, so a key that was left out is named.
pub fn describe(error: &tether_ffi::TetherError, keys: &[String]) -> String {
    use tether_ffi::{KeyProblem, TetherError as E};
    match error {
        E::Cancelled => "Cancelled.".into(),
        E::TimedOut { millis } => format!("Timed out after {millis}ms."),
        E::Unreachable { cause, .. } => format!("Could not reach the host. {cause}"),
        E::HostRejected { .. } => "The host key was not trusted.".into(),
        E::AuthenticationFailed { remaining, skipped } => {
            let refused = if remaining.is_empty() {
                "Authentication failed.".to_owned()
            } else {
                format!("Authentication failed. The server accepts: {}.", remaining.join(", "))
            };
            let keys = skipped.iter().map(|key| {
                let name =
                    keys.get(key.position as usize).cloned().or_else(|| key.fingerprint.clone());
                let why = match &key.problem {
                    KeyProblem::Unreadable { .. } => {
                        "it is not a private key that can be read".to_owned()
                    }
                    KeyProblem::Unsupported { what } => format!("{what} are not supported"),
                    KeyProblem::Locked => "it needs a passphrase that was not given".to_owned(),
                    KeyProblem::WrongPassphrase => "the passphrase was not accepted".to_owned(),
                };
                format!("{} was not used: {why}.", name.unwrap_or_else(|| "A key".into()))
            });
            std::iter::once(refused).chain(keys).collect::<Vec<_>>().join(" ")
        }
        E::MoreFactorsNeeded { remaining } => {
            format!("Another factor is needed: {}.", remaining.join(", "))
        }
        E::NothingToOffer => "No credentials were offered.".into(),
        E::ShellRefused { cause } => format!("Could not open a shell. {cause}"),
        E::Unsupported { what } => format!("This device does not offer {what}."),
        E::Disconnected { cause } => format!("The connection was lost. {cause}"),
        E::SessionEnded => "The session has ended.".into(),
        E::Protocol { cause } => {
            let cause = cause.trim();
            if cause.is_empty() { "Protocol failure.".into() } else { cause.to_owned() }
        }
    }
}

/// A refused login asks for the password again rather than resend one.
pub fn refused(error: &tether_ffi::TetherError) -> bool {
    use tether_ffi::TetherError as E;
    matches!(
        error,
        E::AuthenticationFailed { .. } | E::MoreFactorsNeeded { .. } | E::NothingToOffer
    )
}

/// The server's prompt without a trailing colon (`promptDialogTitle`).
pub fn title_of(prompt: &Prompt) -> String {
    let title = prompt.text.trim().trim_end_matches([':', '：']).trim();
    if title.is_empty() { "Continue".into() } else { title.to_owned() }
}

/// Shown when the server says so; a hidden account password is a password,
/// anything else hidden a code.
fn kind_of(prompt: &Prompt) -> FieldKind {
    if prompt.echo {
        FieldKind::Text
    } else if is_account_password(prompt) {
        FieldKind::Password
    } else {
        FieldKind::Code
    }
}

/// Whether a prompt asks for the account password — and so may be answered
/// with the one already given. Never a one-time code, never a new password.
pub fn is_account_password(prompt: &Prompt) -> bool {
    if prompt.echo {
        return false;
    }
    let folded = prompt.text.to_lowercase();
    let codes = [
        "one-time",
        "verification",
        "otp",
        "token",
        "passcode",
        "authenticator",
        "challenge",
        "re-enter",
    ];
    if codes.iter().any(|word| folded.contains(word)) {
        return false;
    }
    let changes = ["new", "retype", "again", "confirm", "verify", "repeat", "reenter"];
    if folded.split(|c: char| !c.is_alphabetic()).any(|word| changes.contains(&word)) {
        return false;
    }
    let trimmed = folded.trim().trim_matches([':', '：']).trim();
    trimmed == "password" || trimmed.starts_with("password ") || trimmed.ends_with(" password")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prompt(text: &str, echo: bool) -> Prompt {
        Prompt { text: text.into(), echo }
    }

    #[test]
    fn trust_names_the_address_and_shows_the_key() {
        let dialog = trust("h.example", 2222, "ssh-ed25519", "SHA256:x");
        assert_eq!(dialog.title, "Trust h.example:2222?");
        assert_eq!(dialog.message.as_deref(), Some("ssh-ed25519\nSHA256:x"));
        assert_eq!(dialog.actions[0].title, "Reject");
        assert_eq!(trust("h", 22, "a", "f").title, "Trust h?");
    }

    #[test]
    fn a_round_takes_its_title_from_the_first_prompt() {
        let dialog = prompts(
            &[prompt("Password: ", false), prompt("Verification code:", false)],
            "Password: ",
            None,
        );
        assert_eq!(dialog.title, "Password");
        // An instruction that is not exactly the title is shown, as on a Mac.
        assert_eq!(dialog.message.as_deref(), Some("Password:"));
        assert_eq!(prompts(&[prompt("Password:", false)], "Password", None).message, None);
        assert_eq!(dialog.fields[0], Field::new("", FieldKind::Password));
        assert_eq!(dialog.fields[1], Field::new("Verification code", FieldKind::Code));
        assert_eq!(prompts(&[], "Use your key", None).title, "Continue");
        assert_eq!(prompts(&[], "Use your key", None).message.as_deref(), Some("Use your key"));
    }

    #[test]
    fn only_the_account_password_is_one() {
        assert!(is_account_password(&prompt("Password:", false)));
        assert!(is_account_password(&prompt("ada's password: ", false)));
        assert!(is_account_password(&prompt("Password for ada@h:", false)));
        assert!(!is_account_password(&prompt("New password:", false)));
        assert!(!is_account_password(&prompt("Retype password:", false)));
        assert!(!is_account_password(&prompt("One-time password:", false)));
        assert!(!is_account_password(&prompt("Password:", true)));
    }

    #[test]
    fn the_passphrase_says_when_one_was_wrong() {
        assert_eq!(
            passphrase("id_ed25519", Some("SHA256:k"), 1).message.as_deref(),
            Some("SHA256:k")
        );
        assert_eq!(
            passphrase("id_ed25519", Some("SHA256:k"), 2).message.as_deref(),
            Some("The passphrase was not accepted.")
        );
    }

    #[test]
    fn a_failure_reads_as_the_mac_says_it() {
        use tether_ffi::{KeyProblem, SkippedKey, TetherError};
        let failed = TetherError::AuthenticationFailed {
            remaining: vec!["publickey".into(), "password".into()],
            skipped: vec![SkippedKey {
                position: 0,
                fingerprint: None,
                problem: KeyProblem::Locked,
            }],
        };
        assert_eq!(
            describe(&failed, &["id_ed25519".into()]),
            "Authentication failed. The server accepts: publickey, password. id_ed25519 was not used: it needs a passphrase that was not given."
        );
        assert!(refused(&failed));
        let gone = TetherError::Unreachable { endpoint: "h:22".into(), cause: "refused".into() };
        assert_eq!(describe(&gone, &[]), "Could not reach the host. refused");
        assert!(!refused(&gone));
    }

    #[test]
    fn a_failure_closes_a_tab_that_never_showed_a_screen() {
        assert_eq!(could_not_connect("h", "refused", false).actions[0].title, "Close");
        assert_eq!(could_not_connect("h", "refused", true).actions[0].title, "Not Now");
        assert_eq!(lost("localhost", "", true).actions[1].title, "Restart");
    }
}
