//! Moving bytes between this machine and the far side.
//!
//! Both directions write somewhere nobody is looking first and put the
//! result in place only once it is whole. A transfer that is cancelled or
//! fails leaves the destination as it was — a half-written file under the
//! real name is worse than no file, because it looks like the real thing.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use russh_sftp::protocol::OpenFlags;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio_util::sync::CancellationToken;

use crate::error::{Error, Result};
use crate::files::Files;
use crate::path::{join, name_of, parent_of};

/// How much is read before it is written on. Large enough to keep the
/// client's pipelined requests busy, small enough that cancellation and
/// progress are noticed promptly.
const CHUNK: usize = 256 * 1024;

impl Files {
    /// Copies `path` on the far side to `destination` here, returning the
    /// number of bytes.
    ///
    /// `progress` hears the running total after each chunk. `destination` is
    /// replaced if it exists: the caller chose it, and it is on this machine.
    pub async fn download(
        &self,
        path: &str,
        destination: &Path,
        cancellation: &CancellationToken,
        progress: impl Fn(u64) + Send,
    ) -> Result<u64> {
        if cancellation.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let mut source = self.sftp.open(path).await.map_err(|error| self.fail(error, path))?;
        let working = local_working_name(destination);
        let mut target = tokio::fs::File::create(&working)
            .await
            .map_err(|error| Error::local(error, &working))?;

        let copied = copy(&mut source, &mut target, cancellation, &progress)
            .await
            .map_err(|failure| failure.about(|error| self.fail(error.into(), path), &working));
        let finished = match copied {
            Ok(total) => match target.sync_all().await {
                Ok(()) => Ok(total),
                Err(error) => Err(Error::local(error, &working)),
            },
            Err(error) => Err(error),
        };
        drop(target);
        let _ = source.shutdown().await;

        match finished {
            Ok(total) => {
                tokio::fs::rename(&working, destination)
                    .await
                    .map_err(|error| Error::local(error, destination))?;
                Ok(total)
            }
            Err(error) => {
                let _ = tokio::fs::remove_file(&working).await;
                Err(error)
            }
        }
    }

    /// Copies `source` here to `path` on the far side, returning the number
    /// of bytes.
    ///
    /// Refuses when something is already at `path`, unless `replace` is set;
    /// a directory is never replaced. The bytes go to a hidden working file
    /// beside `path` and are renamed into place once complete.
    pub async fn upload(
        &self,
        source: &Path,
        path: &str,
        replace: bool,
        cancellation: &CancellationToken,
        progress: impl Fn(u64) + Send,
    ) -> Result<u64> {
        if cancellation.is_cancelled() {
            return Err(Error::Cancelled);
        }
        // Asked first, so a refusal costs nothing; asked again at the end,
        // because the far side is somebody else's computer and may have
        // changed while the bytes were travelling.
        if !replace && self.lstat(path).await.is_ok() {
            return Err(Error::Exists { path: path.to_owned() });
        }
        let mut local =
            tokio::fs::File::open(source).await.map_err(|error| Error::local(error, source))?;

        let working = remote_working_name(path);
        let flags = OpenFlags::CREATE | OpenFlags::WRITE | OpenFlags::TRUNCATE | OpenFlags::EXCLUDE;
        let mut remote = self
            .sftp
            .open_with_flags(working.as_str(), flags)
            .await
            .map_err(|error| self.fail(error, path))?;

        let copied = copy(&mut local, &mut remote, cancellation, &progress)
            .await
            .map_err(|failure| failure.about_remote(|error| self.fail(error.into(), path), source));
        let closed = remote.shutdown().await;
        let finished = match (copied, closed) {
            (Ok(total), Ok(())) => self.make_room(path, replace).await.map(|()| total),
            (Ok(_), Err(error)) => Err(self.fail(error.into(), path)),
            (Err(error), _) => Err(error),
        };

        let placed = match finished {
            Ok(total) => self
                .sftp
                .rename(working.as_str(), path)
                .await
                .map(|()| total)
                .map_err(|error| self.fail(error, path)),
            Err(error) => Err(error),
        };
        if placed.is_err() {
            let _ = self.sftp.remove_file(working.as_str()).await;
        }
        placed
    }
}

/// Which side of a copy failed, so each is reported against its own path.
enum Failure {
    Cancelled,
    Read(std::io::Error),
    Write(std::io::Error),
}

impl Failure {
    /// A download: the far side is read, this machine is written.
    fn about(self, remote: impl FnOnce(std::io::Error) -> Error, local: &Path) -> Error {
        match self {
            Self::Cancelled => Error::Cancelled,
            Self::Read(error) => remote(error),
            Self::Write(error) => Error::local(error, local),
        }
    }

    /// An upload: this machine is read, the far side is written.
    fn about_remote(self, remote: impl FnOnce(std::io::Error) -> Error, local: &Path) -> Error {
        match self {
            Self::Cancelled => Error::Cancelled,
            Self::Read(error) => Error::local(error, local),
            Self::Write(error) => remote(error),
        }
    }
}

async fn copy<R, W>(
    reader: &mut R,
    writer: &mut W,
    cancellation: &CancellationToken,
    progress: &(impl Fn(u64) + Send),
) -> std::result::Result<u64, Failure>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut buffer = vec![0u8; CHUNK];
    let mut total = 0u64;
    loop {
        let read = tokio::select! {
            _ = cancellation.cancelled() => return Err(Failure::Cancelled),
            read = reader.read(&mut buffer) => read.map_err(Failure::Read)?,
        };
        if read == 0 {
            break;
        }
        tokio::select! {
            _ = cancellation.cancelled() => return Err(Failure::Cancelled),
            written = writer.write_all(&buffer[..read]) => written.map_err(Failure::Write)?,
        }
        total += read as u64;
        progress(total);
    }
    writer.flush().await.map_err(Failure::Write)?;
    Ok(total)
}

/// A name nobody else is using, beside `destination`.
fn local_working_name(destination: &Path) -> PathBuf {
    let name = destination.file_name().map(|name| name.to_string_lossy()).unwrap_or_default();
    destination.with_file_name(format!(".{name}.tether-{}", stamp()))
}

/// The same, on the far side. Hidden, so a directory listing that happens
/// mid-transfer does not show a file that is not finished.
fn remote_working_name(path: &str) -> String {
    join(parent_of(path), &format!(".{}.tether-{}", name_of(path), stamp()))
}

fn stamp() -> String {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("{}-{nanos}", std::process::id())
}
