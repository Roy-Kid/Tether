//! An SFTP session, and what can be asked of it.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use russh_sftp::client::SftpSession;
use russh_sftp::client::error::Error as SftpError;

use crate::entry::{Entry, Kind};
use crate::error::{Error, Result};
use crate::path::{join, name_of};
use crate::transport::{Transport, bridge};

/// Files on the machine at the far end of a [`Transport`].
///
/// One session serves every request, and requests may be in flight at once:
/// a listing does not wait behind a download. Dropping it — or [`close`] —
/// ends the stream, and with it the server.
///
/// [`close`]: Files::close
pub struct Files {
    pub(crate) sftp: SftpSession,
    alive: Arc<AtomicBool>,
}

impl Files {
    /// Starts the protocol over `transport` and waits for the server to agree
    /// on a version.
    ///
    /// Must be called inside a tokio runtime: the bridge onto the transport
    /// is a task of its own.
    pub async fn start(transport: impl Transport) -> Result<Self> {
        let alive = Arc::new(AtomicBool::new(true));
        let stream = bridge(transport, alive.clone());
        let sftp = SftpSession::new(stream).await.map_err(|error| match error {
            SftpError::Status(_) => Error::from_sftp(error, ""),
            other => Error::Disconnected { cause: other.to_string() },
        })?;
        Ok(Self { sftp, alive })
    }

    /// Where the server puts a session that did not ask for anywhere: the
    /// account's home directory, as an absolute path.
    pub async fn home(&self) -> Result<String> {
        self.sftp.canonicalize(".").await.map_err(|error| self.fail(error, "."))
    }

    /// `path` with `.`, `..` and links resolved, as the server sees it.
    pub async fn resolve(&self, path: &str) -> Result<String> {
        self.sftp.canonicalize(path).await.map_err(|error| self.fail(error, path))
    }

    /// What is in `directory`, sorted by name.
    ///
    /// Links are listed as links. Neither `.` nor `..` is included: they are
    /// the protocol's bookkeeping, not something a person put there.
    pub async fn list(&self, directory: &str) -> Result<Vec<Entry>> {
        let listing =
            self.sftp.read_dir(directory).await.map_err(|error| self.fail(error, directory))?;
        let mut entries: Vec<Entry> = listing
            .map(|entry| {
                let name = entry.file_name();
                let path = join(directory, &name);
                Entry::new(name, path, &entry.metadata())
            })
            .collect();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(entries)
    }

    /// What `path` is, looking through a link to what it points at.
    pub async fn stat(&self, path: &str) -> Result<Entry> {
        let metadata = self.sftp.metadata(path).await.map_err(|error| self.fail(error, path))?;
        Ok(Entry::new(name_of(path).to_owned(), path.to_owned(), &metadata))
    }

    /// What `path` is, reporting a link as a link.
    pub async fn lstat(&self, path: &str) -> Result<Entry> {
        let metadata =
            self.sftp.symlink_metadata(path).await.map_err(|error| self.fail(error, path))?;
        Ok(Entry::new(name_of(path).to_owned(), path.to_owned(), &metadata))
    }

    /// Makes one directory. Its parent must exist.
    pub async fn make_directory(&self, path: &str) -> Result<()> {
        match self.sftp.create_dir(path).await {
            Ok(()) => Ok(()),
            Err(error) => Err(self.explain(error, path).await),
        }
    }

    /// Moves `from` to `to`.
    ///
    /// Refuses when something is already at `to`, unless `replace` is set —
    /// and even then never replaces a directory, because a rename that
    /// silently discarded a tree is not what anybody asking to "replace"
    /// meant. SFTP version 3 has no atomic replace, so a replacement is a
    /// removal and a rename; a failure between the two leaves `from` where
    /// it was.
    pub async fn rename(&self, from: &str, to: &str, replace: bool) -> Result<()> {
        self.make_room(to, replace).await?;
        self.sftp.rename(from, to).await.map_err(|error| self.fail(error, from))
    }

    /// Removes a file, a link, or an empty directory.
    pub async fn remove(&self, path: &str) -> Result<()> {
        let entry = self.lstat(path).await?;
        let removed = if entry.kind == Kind::Directory {
            self.sftp.remove_dir(path).await
        } else {
            self.sftp.remove_file(path).await
        };
        match removed {
            Ok(()) => Ok(()),
            Err(error) => Err(self.explain(error, path).await),
        }
    }

    /// Removes `path` and everything under it, returning how many things
    /// were removed.
    ///
    /// Walks with `lstat` semantics: a link inside the tree is removed as a
    /// link and never followed, so a tree cannot reach outside itself. Stops
    /// at the first failure; what was already removed stays removed, and the
    /// error says where it stopped.
    pub async fn remove_tree(&self, path: &str) -> Result<u64> {
        let root = self.lstat(path).await?;
        if root.kind != Kind::Directory {
            self.remove(path).await?;
            return Ok(1);
        }

        // Post-order without recursion: a directory is visited once to list
        // it and again, after its children, to remove it.
        let mut removed = 0;
        let mut pending = vec![(path.to_owned(), false)];
        while let Some((directory, listed)) = pending.pop() {
            if listed {
                self.sftp
                    .remove_dir(directory.as_str())
                    .await
                    .map_err(|error| self.fail(error, &directory))?;
                removed += 1;
                continue;
            }
            pending.push((directory.clone(), true));
            for entry in self.list(&directory).await? {
                if entry.kind == Kind::Directory {
                    pending.push((entry.path, false));
                } else {
                    self.sftp
                        .remove_file(entry.path.as_str())
                        .await
                        .map_err(|error| self.fail(error, &entry.path))?;
                    removed += 1;
                }
            }
        }
        Ok(removed)
    }

    /// Ends the session. Requests after this fail as disconnected.
    pub async fn close(&self) {
        self.alive.store(false, Ordering::SeqCst);
        let _ = self.sftp.close().await;
    }

    /// Clears `path` for something new, or says why it cannot be.
    pub(crate) async fn make_room(&self, path: &str, replace: bool) -> Result<()> {
        let existing = match self.lstat(path).await {
            Ok(entry) => entry,
            Err(Error::NotFound { .. }) => return Ok(()),
            Err(error) => return Err(error),
        };
        if !replace || existing.kind == Kind::Directory {
            return Err(Error::Exists { path: path.to_owned() });
        }
        self.sftp.remove_file(path).await.map_err(|error| self.fail(error, path))
    }

    /// A protocol failure about `path`, unless the session has ended — in
    /// which case that is the answer, whatever the request's own error said.
    pub(crate) fn fail(&self, error: SftpError, path: &str) -> Error {
        if !self.alive.load(Ordering::SeqCst) {
            return Error::Disconnected { cause: "the session has ended".to_owned() };
        }
        Error::from_sftp(error, path)
    }

    /// Like [`fail`](Self::fail), but turns SFTP version 3's catch-all
    /// `Failure` into the specific answer by asking the server what is at
    /// `path` now.
    async fn explain(&self, error: SftpError, path: &str) -> Error {
        let error = self.fail(error, path);
        if !matches!(error, Error::Failed { .. }) {
            return error;
        }
        match self.lstat(path).await {
            Ok(entry) if entry.kind == Kind::Directory => match self.list(path).await {
                Ok(children) if !children.is_empty() => Error::NotEmpty { path: path.to_owned() },
                _ => Error::Exists { path: path.to_owned() },
            },
            Ok(_) => Error::Exists { path: path.to_owned() },
            Err(_) => error,
        }
    }
}
