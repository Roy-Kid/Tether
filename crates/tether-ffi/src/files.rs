//! Files where a session's shell is running, for a Swift consumer.
//!
//! One adapter, as for tmux: SFTP is spoken over [`tether_core::Channel`],
//! which is a subsystem channel on a remote session, `ssh -s` through an
//! OpenSSH master, and this machine's `sftp-server` on a local one. The
//! protocol above it was written once (Decisions/0013).

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use tether_core::{Channel, Connection};

use crate::{CancellationToken, RemoteConnection, TetherError};

/// How long the server is given to start and agree on a version.
const START_TIMEOUT: Duration = Duration::from_secs(15);

struct Sftp(Channel);

#[async_trait::async_trait]
impl tether_files::Transport for Sftp {
    async fn read(&mut self) -> tether_files::Result<Option<Vec<u8>>> {
        self.0
            .read()
            .await
            .map_err(|error| tether_files::Error::Disconnected { cause: error.cause })
    }
    async fn write(&mut self, bytes: &[u8]) -> tether_files::Result<()> {
        self.0
            .write(bytes)
            .await
            .map_err(|error| tether_files::Error::Disconnected { cause: error.cause })
    }
    async fn close(&mut self) {
        self.0.close().await;
    }
}

/// What an entry is. A link is reported as a link; [`RemoteFiles::stat`]
/// looks through it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FileKind {
    File,
    Directory,
    Link,
    Other,
}

/// A file, directory or link on the far side.
///
/// `name` is exactly what the server sent: data, not a path, and not safe to
/// show a person or use as a local file name without cleaning (spec §18).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub kind: FileKind,
    pub size: u64,
    /// Seconds since the Unix epoch, when the server said.
    pub modified: Option<u64>,
    /// Permission bits, without the type.
    pub permissions: u32,
}

impl From<tether_files::Entry> for FileEntry {
    fn from(entry: tether_files::Entry) -> Self {
        Self {
            name: entry.name,
            path: entry.path,
            kind: match entry.kind {
                tether_files::Kind::File => FileKind::File,
                tether_files::Kind::Directory => FileKind::Directory,
                tether_files::Kind::Link => FileKind::Link,
                tether_files::Kind::Other => FileKind::Other,
            },
            size: entry.size,
            modified: entry.modified,
            permissions: entry.permissions,
        }
    }
}

/// Why a file operation did not happen, in shapes a person can act on.
///
/// The server's status code is context inside `cause`, never a case of its
/// own (spec §18).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum FileError {
    #[error("{path} does not exist")]
    NotFound { path: String },
    #[error("{path} already exists")]
    Exists { path: String },
    #[error("not allowed to change {path}")]
    PermissionDenied { path: String },
    #[error("{path} is not empty")]
    NotEmpty { path: String },
    #[error("cancelled")]
    Cancelled,
    #[error("the connection was lost: {cause}")]
    Disconnected { cause: String },
    #[error("{cause}")]
    Failed { cause: String },
}

impl From<tether_files::Error> for FileError {
    fn from(error: tether_files::Error) -> Self {
        use tether_files::Error;
        match error {
            Error::NotFound { path } => Self::NotFound { path },
            Error::Exists { path } => Self::Exists { path },
            Error::PermissionDenied { path } => Self::PermissionDenied { path },
            Error::NotEmpty { path } => Self::NotEmpty { path },
            Error::Cancelled => Self::Cancelled,
            Error::Disconnected { cause } => Self::Disconnected { cause },
            Error::Failed { cause } => Self::Failed { cause },
        }
    }
}

/// Hears how far a transfer has got: the running total in bytes, after each
/// chunk. Called from a background thread.
#[uniffi::export(with_foreign)]
pub trait TransferProgress: Send + Sync {
    fn advanced(&self, bytes: u64);
}

#[uniffi::export(async_runtime = "tokio")]
impl RemoteConnection {
    /// Starts a file session where this lease's shell is running.
    ///
    /// A session of its own, beside the shell: a listing never waits behind
    /// what the terminal is doing, and closing the files closes nothing else.
    pub async fn files(
        &self,
        cancellation: Arc<CancellationToken>,
    ) -> Result<Arc<RemoteFiles>, TetherError> {
        let start = async {
            let channel = self
                .inner
                .sftp()
                .await
                .map_err(|error| TetherError::Protocol { cause: error.cause })?;
            tether_files::Files::start(Sftp(channel))
                .await
                .map_err(|error| TetherError::Protocol { cause: error.to_string() })
        };
        tokio::select! {
            biased;
            _ = cancellation.inner.cancelled() => Err(TetherError::Cancelled),
            started = tokio::time::timeout(START_TIMEOUT, start) => {
                let files = started.map_err(|_| TetherError::TimedOut {
                    millis: START_TIMEOUT.as_millis() as u64,
                })??;
                let local = matches!(self.inner, Connection::Local);
                Ok(Arc::new(RemoteFiles { inner: files, local, _connection: self.inner.clone() }))
            }
        }
    }
}

/// Files on the machine a session's shell is running on.
///
/// Holds the lease it was opened on, so the connection outlives the shell
/// that granted it for as long as a browser is open.
#[derive(uniffi::Object)]
pub struct RemoteFiles {
    inner: tether_files::Files,
    local: bool,
    _connection: Connection,
}

#[uniffi::export(async_runtime = "tokio")]
impl RemoteFiles {
    /// Whether these files are on this machine, so a path is also a local
    /// path: a preview can show the file itself instead of a copy.
    pub fn is_local(&self) -> bool {
        self.local
    }

    /// The account's home directory, as an absolute path.
    pub async fn home(&self) -> Result<String, FileError> {
        Ok(self.inner.home().await?)
    }

    /// `path` with `.`, `..` and links resolved, as the server sees it.
    pub async fn resolve(&self, path: String) -> Result<String, FileError> {
        Ok(self.inner.resolve(&path).await?)
    }

    /// What is in `directory`, sorted by name, links listed as links.
    pub async fn list(
        &self,
        directory: String,
        cancellation: Arc<CancellationToken>,
    ) -> Result<Vec<FileEntry>, FileError> {
        tokio::select! {
            biased;
            _ = cancellation.inner.cancelled() => Err(FileError::Cancelled),
            listed = self.inner.list(&directory) => {
                Ok(listed?.into_iter().map(FileEntry::from).collect())
            }
        }
    }

    /// What `path` is, looking through a link.
    pub async fn stat(&self, path: String) -> Result<FileEntry, FileError> {
        Ok(self.inner.stat(&path).await?.into())
    }

    /// What `path` is, reporting a link as a link.
    pub async fn lstat(&self, path: String) -> Result<FileEntry, FileError> {
        Ok(self.inner.lstat(&path).await?.into())
    }

    /// Copies `path` to `destination` on this machine, returning the bytes
    /// copied. `destination` is replaced if it exists, and appears only once
    /// the copy is whole.
    pub async fn download(
        &self,
        path: String,
        destination: String,
        progress: Option<Arc<dyn TransferProgress>>,
        cancellation: Arc<CancellationToken>,
    ) -> Result<u64, FileError> {
        let destination = local_path(&destination)?;
        let report = move |bytes| {
            if let Some(progress) = &progress {
                progress.advanced(bytes);
            }
        };
        Ok(self.inner.download(&path, destination, &cancellation.inner, report).await?)
    }

    /// Copies `source` on this machine to `path`, returning the bytes
    /// copied. Refuses to replace an existing file unless `replace` is set,
    /// and never replaces a directory.
    pub async fn upload(
        &self,
        source: String,
        path: String,
        replace: bool,
        progress: Option<Arc<dyn TransferProgress>>,
        cancellation: Arc<CancellationToken>,
    ) -> Result<u64, FileError> {
        let source = local_path(&source)?;
        let report = move |bytes| {
            if let Some(progress) = &progress {
                progress.advanced(bytes);
            }
        };
        Ok(self.inner.upload(source, &path, replace, &cancellation.inner, report).await?)
    }

    pub async fn make_directory(&self, path: String) -> Result<(), FileError> {
        Ok(self.inner.make_directory(&path).await?)
    }

    /// Moves `from` to `to`, replacing a file at `to` only when asked.
    pub async fn rename(&self, from: String, to: String, replace: bool) -> Result<(), FileError> {
        Ok(self.inner.rename(&from, &to, replace).await?)
    }

    /// Removes a file, a link, or an empty directory.
    pub async fn remove(&self, path: String) -> Result<(), FileError> {
        Ok(self.inner.remove(&path).await?)
    }

    /// Removes `path` and everything under it without following links,
    /// returning how many things were removed. Cancelling stops the walk;
    /// what was removed stays removed.
    pub async fn remove_tree(
        &self,
        path: String,
        cancellation: Arc<CancellationToken>,
    ) -> Result<u64, FileError> {
        tokio::select! {
            biased;
            _ = cancellation.inner.cancelled() => Err(FileError::Cancelled),
            removed = self.inner.remove_tree(&path) => Ok(removed?),
        }
    }

    /// Ends the file session. The shell is untouched.
    pub async fn close(&self) {
        self.inner.close().await;
    }
}

/// A path on this machine, which must be absolute: a relative one would be
/// resolved against whatever directory the process happens to be in.
fn local_path(path: &str) -> Result<&Path, FileError> {
    let local = Path::new(path);
    if local.is_absolute() {
        Ok(local)
    } else {
        Err(FileError::Failed { cause: format!("{path} is not an absolute path") })
    }
}
