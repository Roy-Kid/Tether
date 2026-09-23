//! One thing in a directory.

use russh_sftp::client::fs::Metadata;
use russh_sftp::protocol::FileType;

/// What an entry is, as far as the server said.
///
/// A link is reported as a link: whether to look through it is the caller's
/// decision (`stat` does, `lstat` and a listing do not), because a browser
/// that silently followed links would show a directory in two places and
/// delete through one of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    File,
    Directory,
    Link,
    /// A socket, a device, a pipe — present, and nothing to open.
    Other,
}

/// A file, directory or link, and what the server knows about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// The last component, exactly as the server sent it. Data, not a path:
    /// it may contain anything a file name can, and nothing here trusts it
    /// to be free of `..` or control characters.
    pub name: String,
    /// Where it is on the far side.
    pub path: String,
    pub kind: Kind,
    /// In bytes. Zero when the server did not say.
    pub size: u64,
    /// Seconds since the Unix epoch, when the server said.
    pub modified: Option<u64>,
    /// The permission bits, without the type.
    pub permissions: u32,
}

impl Entry {
    pub(crate) fn new(name: String, path: String, metadata: &Metadata) -> Self {
        let kind = match metadata.file_type() {
            FileType::Dir => Kind::Directory,
            FileType::File => Kind::File,
            FileType::Symlink => Kind::Link,
            FileType::Other => Kind::Other,
        };
        Self {
            name,
            path,
            kind,
            size: metadata.size.unwrap_or(0),
            modified: metadata.mtime.map(u64::from),
            permissions: metadata.permissions.unwrap_or(0) & 0o7777,
        }
    }
}
