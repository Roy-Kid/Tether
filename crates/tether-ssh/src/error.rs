//! What can go wrong, in this crate's own words.
//!
//! `russh::Error` never appears here. A consumer that had to match on it would
//! be coupled to the protocol library we chose, and swapping that library is
//! exactly what this crate exists to make possible (spec §8).

/// A failure reaching, trusting, or using a remote host.
#[derive(Debug, thiserror::Error)]
pub enum SshError {
    #[error("could not reach {endpoint}: {cause}")]
    Unreachable { endpoint: String, cause: String },

    /// The host presented a key the verifier refused. Distinct from an
    /// authentication failure: the *server* failed our check, not the reverse,
    /// and the two want very different words in front of a person.
    #[error("host key for {endpoint} was not trusted")]
    HostRejected { endpoint: String },

    #[error("authentication failed")]
    AuthFailed,

    /// The person abandoned an interactive exchange. Not a failure to
    /// authenticate — nothing was attempted (spec §10).
    #[error("the person declined to answer")]
    Declined,

    /// A private key could not be used — it was locked and every passphrase
    /// offered was wrong. Its own words, because "authentication failed"
    /// would send a person to check an account that was never asked about.
    #[error("the key could not be used: {0}")]
    Key(#[from] crate::key::KeyError),

    #[error("the server refused to open a shell: {cause}")]
    ShellRefused { cause: String },

    #[error("the connection was lost: {cause}")]
    Disconnected { cause: String },

    #[error("protocol failure: {cause}")]
    Protocol { cause: String },
}

impl SshError {
    pub(crate) fn protocol(cause: impl std::fmt::Display) -> Self {
        Self::Protocol { cause: cause.to_string() }
    }
}

impl From<russh::Error> for SshError {
    fn from(error: russh::Error) -> Self {
        match error {
            russh::Error::Disconnect | russh::Error::HUP => {
                Self::Disconnected { cause: error.to_string() }
            }
            other => Self::protocol(other),
        }
    }
}
