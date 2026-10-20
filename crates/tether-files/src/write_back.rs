//! Putting a file someone edited here back where it came from.

use std::path::Path;

use russh_sftp::protocol::{FileAttributes, OpenFlags};
use tokio::io::AsyncWriteExt;
use tokio_util::sync::CancellationToken;

use crate::entry::{Entry, Kind};
use crate::error::{Error, Result};
use crate::files::Files;
use crate::path::name_of;
use crate::transfer::{copy, remote_working_name};

impl Files {
    /// Puts `source` here in place of `path` on the far side — but only while
    /// `path` is still the file the edit was made to: `expected_size` bytes,
    /// last modified at `expected_modified`.
    ///
    /// Asked before the bytes travel and again just before they are put in
    /// place, so a change made on the far side meanwhile is
    /// [`Error::Changed`], never overwritten — to the second: SFTP version 3
    /// keeps times no finer, so a change of the same size within the same
    /// second as the one compared against goes unseen. A link is written
    /// through, not replaced. The file keeps its permission bits: a script
    /// saved from an editor is still a script. Being a new file, it does not
    /// keep its owner, extended attributes or hard links. Returns what `path`
    /// is afterwards.
    pub async fn write_back(
        &self,
        source: &Path,
        path: &str,
        expected_size: u64,
        expected_modified: Option<u64>,
        cancellation: &CancellationToken,
        progress: impl Fn(u64) + Send,
    ) -> Result<Entry> {
        if cancellation.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let target = match self.resolve(path).await {
            Ok(target) => target,
            Err(Error::NotFound { .. }) => return Err(Error::Changed { path: path.to_owned() }),
            Err(error) => return Err(error),
        };
        let original = self.unchanged(&target, path, expected_size, expected_modified).await?;
        let mut local =
            tokio::fs::File::open(source).await.map_err(|error| Error::local(error, source))?;

        let working = remote_working_name(&target);
        let flags = OpenFlags::CREATE | OpenFlags::WRITE | OpenFlags::TRUNCATE | OpenFlags::EXCLUDE;
        let mut remote = self
            .sftp
            .open_with_flags(working.as_str(), flags)
            .await
            .map_err(|error| self.fail(error, path))?;
        let copied = copy(&mut local, &mut remote, cancellation, &progress)
            .await
            .map_err(|failure| failure.about_remote(|error| self.fail(error.into(), path), source));
        // Zero is a server that did not say, not a file nobody may read.
        let kept = if copied.is_ok() && original.permissions != 0 {
            let mut attributes = FileAttributes::empty();
            attributes.permissions = Some(original.permissions);
            remote.set_metadata(attributes).await.map_err(|error| self.fail(error, path))
        } else {
            Ok(())
        };
        // What the file is once it is in place, read from the handle: a
        // question asked after the swap could fail for a write that landed.
        let written = remote.metadata().await.ok();
        let closed = remote.shutdown().await.map_err(|error| self.fail(error.into(), path));

        let ready = match (copied, kept, closed) {
            (Ok(_), Ok(()), Ok(())) => Ok(()),
            (Err(error), _, _) | (Ok(_), Err(error), _) | (Ok(_), Ok(()), Err(error)) => Err(error),
        };
        if let Err(error) = ready {
            let _ = self.sftp.remove_file(working.as_str()).await;
            return Err(error);
        }
        self.replace(&working, &target, path, &original).await?;
        match written {
            Some(metadata) => Ok(Entry::new(name_of(path).to_owned(), path.to_owned(), &metadata)),
            None => self.stat(path).await,
        }
    }

    /// The file at `target`, as long as it is still the one the edit was
    /// made to. `path` is what the person opened, which is what they are told.
    async fn unchanged(
        &self,
        target: &str,
        path: &str,
        size: u64,
        modified: Option<u64>,
    ) -> Result<Entry> {
        match self.stat(target).await {
            Ok(entry)
                if entry.kind == Kind::File && entry.size == size && entry.modified == modified =>
            {
                Ok(entry)
            }
            Ok(_) | Err(Error::NotFound { .. }) => Err(Error::Changed { path: path.to_owned() }),
            Err(error) => Err(error),
        }
    }

    /// Asks once more, then swaps the finished copy in. SFTP version 3 has
    /// no atomic replace, so the original steps aside under a hidden name
    /// first and is put back if the copy cannot take its place: at every
    /// moment one of the two is at `target`, and neither is deleted until the
    /// other is there. The copy goes on any failure; the original never does.
    async fn replace(
        &self,
        working: &str,
        target: &str,
        path: &str,
        original: &Entry,
    ) -> Result<()> {
        let swapped = self.swap(working, target, path, original).await;
        if swapped.is_err() {
            let _ = self.sftp.remove_file(working).await;
        }
        swapped
    }

    async fn swap(&self, working: &str, target: &str, path: &str, original: &Entry) -> Result<()> {
        self.unchanged(target, path, original.size, original.modified).await?;
        // A name of its own each time: one left by a run that ended halfway
        // would refuse the rename, and every later write-back with it.
        let aside = format!("{}-previous", remote_working_name(target));
        self.sftp.rename(target, aside.as_str()).await.map_err(|error| self.fail(error, path))?;
        if let Err(error) = self.sftp.rename(working, target).await {
            let _ = self.sftp.rename(aside.as_str(), target).await;
            return Err(self.fail(error, path));
        }
        let _ = self.sftp.remove_file(aside.as_str()).await;
        Ok(())
    }
}
