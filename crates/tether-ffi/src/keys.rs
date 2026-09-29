//! Private keys at the seam: the passphrase question that travels up, and
//! the account of a key that was left out that travels back.

use std::sync::Arc;

use tether_core::ssh::{KeyDescription, KeyError, KeyUnlocker};

/// A key that needs its passphrase, as a person is shown it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LockedKey {
    /// `SHA256:…`. Absent for the formats that keep even the public half
    /// behind the passphrase.
    pub fingerprint: Option<String>,
    /// The key's own comment, often `user@host`; empty when encrypted.
    pub comment: String,
}

/// Asks the application for a key's passphrase.
///
/// Upward, like the prompter: only the application can put a question in
/// front of a person. Asked only once the server has said it would take the
/// key, where the format lets the server be asked first.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait PassphrasePrompter: Send + Sync {
    /// `attempt` counts from one; a second call means the first was wrong.
    /// `None` is the person declining, which ends the login as a decline.
    async fn passphrase(&self, key: LockedKey, attempt: u32) -> Option<String>;
}

/// Why a key could not be used. Our words, not the parser's (spec §18).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum KeyProblem {
    /// Not a private key in a format this build reads. `cause` is diagnostic.
    Unreadable { cause: String },
    /// A kind this build cannot sign with, such as a hardware security key.
    Unsupported { what: String },
    /// Protected by a passphrase that was not given: nothing could ask for
    /// one, or the person asked said no.
    Locked,
    /// Every passphrase offered was wrong.
    WrongPassphrase,
}

/// A key left out of a login.
///
/// Named by its place among the secrets the application passed, counting
/// from zero — the application built that list, so it can say which file or
/// keychain item it was. The core never learns a file name (spec §4).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SkippedKey {
    pub position: u32,
    pub fingerprint: Option<String>,
    pub problem: KeyProblem,
}

impl From<KeyError> for KeyProblem {
    fn from(error: KeyError) -> Self {
        match error {
            KeyError::Unreadable { cause } => Self::Unreadable { cause },
            KeyError::Unsupported { what } => Self::Unsupported { what },
            KeyError::Locked => Self::Locked,
            KeyError::WrongPassphrase => Self::WrongPassphrase,
        }
    }
}

impl From<tether_core::SkippedKey> for SkippedKey {
    fn from(skipped: tether_core::SkippedKey) -> Self {
        Self {
            // A credential list longer than u32 is not one a person built.
            position: u32::try_from(skipped.position).unwrap_or(u32::MAX),
            fingerprint: skipped.fingerprint,
            problem: skipped.problem.into(),
        }
    }
}

pub(crate) struct ForeignUnlocker(pub(crate) Arc<dyn PassphrasePrompter>);

#[async_trait::async_trait]
impl KeyUnlocker for ForeignUnlocker {
    async fn passphrase(&self, key: &KeyDescription, attempt: u32) -> Option<String> {
        let key = LockedKey { fingerprint: key.fingerprint.clone(), comment: key.comment.clone() };
        self.0.passphrase(key, attempt).await
    }
}
