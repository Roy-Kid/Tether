//! What can go wrong, in our words.

use russh_sftp::client::error::Error as SftpError;
use russh_sftp::protocol::StatusCode;

/// Why a file operation did not happen.
///
/// The shapes a person can act on — it is not there, it is already there,
/// you may not, it is not empty — and a sentence for the rest. The server's
/// status number is diagnostic context inside `cause`, never something a
/// consumer matches on (spec §18): switching SFTP libraries must not be a
/// breaking change for an application.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    #[error("{path} does not exist")]
    NotFound { path: String },
    #[error("{path} already exists")]
    Exists { path: String },
    #[error("not allowed to change {path}")]
    PermissionDenied { path: String },
    #[error("{path} is not empty")]
    NotEmpty { path: String },
    /// The caller asked for it to stop, and what it had started was undone.
    #[error("cancelled")]
    Cancelled,
    /// The session ended: the stream closed, or the server stopped answering.
    #[error("the connection was lost: {cause}")]
    Disconnected { cause: String },
    #[error("{cause}")]
    Failed { cause: String },
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    /// Translates a protocol failure about `path`.
    ///
    /// SFTP version 3 — the one OpenSSH speaks — has no code for "exists" or
    /// "not empty": both arrive as a bare `Failure`. Those two are therefore
    /// decided by asking the server again, where the operation is, rather
    /// than guessed from a message meant for a person.
    pub(crate) fn from_sftp(error: SftpError, path: &str) -> Self {
        match error {
            SftpError::Status(status) => match status.status_code {
                StatusCode::NoSuchFile => Self::NotFound { path: path.to_owned() },
                StatusCode::PermissionDenied => Self::PermissionDenied { path: path.to_owned() },
                StatusCode::NoConnection | StatusCode::ConnectionLost => {
                    Self::Disconnected { cause: status.error_message }
                }
                code => Self::Failed { cause: describe(code, &status.error_message, path) },
            },
            SftpError::IO(cause) => Self::Disconnected { cause },
            SftpError::Timeout => {
                Self::Disconnected { cause: "the server stopped answering".to_owned() }
            }
            other => Self::Failed { cause: other.to_string() },
        }
    }

    pub(crate) fn local(error: std::io::Error, path: &std::path::Path) -> Self {
        let path = path.display().to_string();
        match error.kind() {
            std::io::ErrorKind::NotFound => Self::NotFound { path },
            std::io::ErrorKind::PermissionDenied => Self::PermissionDenied { path },
            _ => Self::Failed { cause: format!("{path}: {error}") },
        }
    }
}

fn describe(code: StatusCode, message: &str, path: &str) -> String {
    let message = message.trim();
    if message.is_empty() { format!("{path}: {code}") } else { format!("{path}: {message}") }
}
