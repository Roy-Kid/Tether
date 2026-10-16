//! Files over a real `sftp-server`, spoken to on pipes.
//!
//! No host, no key, no network: the server is the one OpenSSH runs for every
//! SFTP session, started as a child of the test. It is the same program a
//! remote `sshd` hands a subsystem request to, so what passes here is the
//! protocol, not a fake of it.
//!
//! Unix-only: the suite starts `sftp-server` from OpenSSH's Unix install
//! paths and asserts symlink behaviour through `std::os::unix::fs`.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use tether_files::{Error, Files, Kind, Transport};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::sync::CancellationToken;

/// Where OpenSSH installs the server on the systems this runs on.
const SERVERS: &[&str] = &[
    "/usr/libexec/sftp-server",
    "/usr/lib/openssh/sftp-server",
    "/usr/libexec/openssh/sftp-server",
    "/usr/lib/ssh/sftp-server",
];

struct Process {
    child: tokio::process::Child,
    input: tokio::process::ChildStdin,
    output: tokio::process::ChildStdout,
}

#[async_trait::async_trait]
impl Transport for Process {
    async fn read(&mut self) -> tether_files::Result<Option<Vec<u8>>> {
        let mut bytes = vec![0; 32 * 1024];
        let n = self
            .output
            .read(&mut bytes)
            .await
            .map_err(|e| Error::Disconnected { cause: e.to_string() })?;
        bytes.truncate(n);
        Ok(if n == 0 { None } else { Some(bytes) })
    }
    async fn write(&mut self, bytes: &[u8]) -> tether_files::Result<()> {
        self.input.write_all(bytes).await.map_err(|e| Error::Disconnected { cause: e.to_string() })
    }
    async fn close(&mut self) {
        let _ = self.child.kill().await;
    }
}

/// A started session, or `None` where no server is installed — unless the
/// environment says one must be, which is how CI refuses a silent skip.
async fn files() -> Option<Files> {
    let Some(server) = SERVERS.iter().find(|path| Path::new(path).exists()) else {
        assert!(
            std::env::var_os("TETHER_REQUIRE_SFTP").is_none(),
            "TETHER_REQUIRE_SFTP is set and no sftp-server is installed"
        );
        eprintln!("skipping: no sftp-server on this machine");
        return None;
    };
    let mut child = tokio::process::Command::new(server)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("sftp-server starts");
    let transport =
        Process { input: child.stdin.take().unwrap(), output: child.stdout.take().unwrap(), child };
    Some(Files::start(transport).await.expect("the session initialises"))
}

/// A directory of this test's own, removed when it goes out of scope.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("tether-files-{name}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self, relative: &str) -> PathBuf {
        self.0.join(relative)
    }
    fn remote(&self, relative: &str) -> String {
        self.path(relative).to_string_lossy().into_owned()
    }
    fn names(&self, relative: &str) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(self.path(relative))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Bytes that are not text and not a repeating pattern, so an off-by-one in
/// an offset shows up as a mismatch rather than as the same byte again.
fn noise(len: usize) -> Vec<u8> {
    let mut state = 0x2545_f491_4f6c_dd1d_u64;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state as u8
        })
        .collect()
}

fn nothing(_: u64) {}

#[tokio::test]
async fn home_is_an_absolute_path() {
    let Some(files) = files().await else { return };
    let home = files.home().await.unwrap();
    assert!(home.starts_with('/'), "{home}");
}

#[tokio::test]
async fn a_listing_names_what_is_there_and_says_what_each_thing_is() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("list");
    std::fs::write(scratch.path("b.txt"), b"abc").unwrap();
    std::fs::create_dir(scratch.path("a")).unwrap();
    std::os::unix::fs::symlink(scratch.path("b.txt"), scratch.path("c")).unwrap();

    let entries = files.list(&scratch.remote("")).await.unwrap();
    let summary: Vec<(&str, Kind, u64)> =
        entries.iter().map(|entry| (entry.name.as_str(), entry.kind, entry.size)).collect();

    // Sorted by name, and neither `.` nor `..`: a listing is what is in the
    // directory, not the protocol's bookkeeping about it.
    assert_eq!(summary[0].0, "a");
    assert_eq!(summary[0].1, Kind::Directory);
    assert_eq!(summary[1], ("b.txt", Kind::File, 3));
    assert_eq!(summary[2].0, "c");
    assert_eq!(summary[2].1, Kind::Link);
    assert_eq!(entries.len(), 3);
    assert_eq!(entries[1].path, scratch.remote("b.txt"));
    assert!(entries[1].modified.is_some());
}

#[tokio::test]
async fn stat_follows_a_link_and_lstat_does_not() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("stat");
    std::fs::write(scratch.path("target"), b"12345").unwrap();
    std::os::unix::fs::symlink(scratch.path("target"), scratch.path("link")).unwrap();

    let followed = files.stat(&scratch.remote("link")).await.unwrap();
    assert_eq!((followed.kind, followed.size), (Kind::File, 5));
    assert_eq!(followed.name, "link");

    let itself = files.lstat(&scratch.remote("link")).await.unwrap();
    assert_eq!(itself.kind, Kind::Link);
}

#[tokio::test]
async fn a_missing_path_is_not_found_rather_than_a_failure() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("missing");
    let path = scratch.remote("nothing-here");
    assert_eq!(files.stat(&path).await.unwrap_err(), Error::NotFound { path: path.clone() });
}

#[tokio::test]
async fn a_download_is_the_same_bytes_and_reports_how_far_it_got() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("download");
    let bytes = noise(700 * 1024 + 13);
    std::fs::write(scratch.path("remote.bin"), &bytes).unwrap();

    let reported = Arc::new(AtomicU64::new(0));
    let seen = reported.clone();
    let copied = files
        .download(
            &scratch.remote("remote.bin"),
            &scratch.path("local.bin"),
            &CancellationToken::new(),
            move |done| seen.store(done, Ordering::SeqCst),
        )
        .await
        .unwrap();

    assert_eq!(copied, bytes.len() as u64);
    assert_eq!(reported.load(Ordering::SeqCst), bytes.len() as u64);
    assert_eq!(std::fs::read(scratch.path("local.bin")).unwrap(), bytes);
    assert_eq!(scratch.names(""), ["local.bin", "remote.bin"]);
}

#[tokio::test]
async fn a_cancelled_download_leaves_nothing_behind() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("download-cancel");
    std::fs::write(scratch.path("remote.bin"), noise(256 * 1024)).unwrap();
    let cancelled = CancellationToken::new();
    cancelled.cancel();

    let result = files
        .download(&scratch.remote("remote.bin"), &scratch.path("local.bin"), &cancelled, nothing)
        .await;

    assert_eq!(result.unwrap_err(), Error::Cancelled);
    assert_eq!(scratch.names(""), ["remote.bin"]);
}

#[tokio::test]
async fn an_upload_arrives_whole_and_leaves_no_working_file() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("upload");
    let bytes = noise(500 * 1024 + 7);
    std::fs::write(scratch.path("local.bin"), &bytes).unwrap();
    std::fs::create_dir(scratch.path("remote")).unwrap();

    let copied = files
        .upload(
            &scratch.path("local.bin"),
            &scratch.remote("remote/arrived.bin"),
            false,
            &CancellationToken::new(),
            nothing,
        )
        .await
        .unwrap();

    assert_eq!(copied, bytes.len() as u64);
    assert_eq!(std::fs::read(scratch.path("remote/arrived.bin")).unwrap(), bytes);
    assert_eq!(scratch.names("remote"), ["arrived.bin"]);
}

#[tokio::test]
async fn an_upload_does_not_replace_a_file_unless_asked_to() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("upload-exists");
    std::fs::write(scratch.path("local.txt"), b"new").unwrap();
    std::fs::write(scratch.path("there.txt"), b"old").unwrap();
    let there = scratch.remote("there.txt");
    let local = scratch.path("local.txt");
    let token = CancellationToken::new();

    let refused = files.upload(&local, &there, false, &token, nothing).await;
    assert_eq!(refused.unwrap_err(), Error::Exists { path: there.clone() });
    assert_eq!(std::fs::read(scratch.path("there.txt")).unwrap(), b"old");

    files.upload(&local, &there, true, &token, nothing).await.unwrap();
    assert_eq!(std::fs::read(scratch.path("there.txt")).unwrap(), b"new");
    assert_eq!(scratch.names(""), ["local.txt", "there.txt"]);
}

#[tokio::test]
async fn a_cancelled_upload_leaves_nothing_on_the_far_side() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("upload-cancel");
    std::fs::write(scratch.path("local.bin"), noise(256 * 1024)).unwrap();
    std::fs::create_dir(scratch.path("remote")).unwrap();
    let cancelled = CancellationToken::new();
    cancelled.cancel();

    let result = files
        .upload(
            &scratch.path("local.bin"),
            &scratch.remote("remote/never.bin"),
            false,
            &cancelled,
            nothing,
        )
        .await;

    assert_eq!(result.unwrap_err(), Error::Cancelled);
    assert!(scratch.names("remote").is_empty());
}

#[tokio::test]
async fn a_directory_is_made_once() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("mkdir");
    let path = scratch.remote("made");

    files.make_directory(&path).await.unwrap();
    assert!(scratch.path("made").is_dir());
    assert_eq!(files.make_directory(&path).await.unwrap_err(), Error::Exists { path });
}

#[tokio::test]
async fn a_rename_moves_and_only_replaces_when_asked() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("rename");
    std::fs::write(scratch.path("one"), b"1").unwrap();
    std::fs::write(scratch.path("two"), b"2").unwrap();
    std::fs::create_dir(scratch.path("into")).unwrap();

    files.rename(&scratch.remote("one"), &scratch.remote("into/one"), false).await.unwrap();
    assert_eq!(scratch.names("into"), ["one"]);

    let refused = files.rename(&scratch.remote("two"), &scratch.remote("into/one"), false).await;
    assert_eq!(refused.unwrap_err(), Error::Exists { path: scratch.remote("into/one") });
    assert_eq!(std::fs::read(scratch.path("into/one")).unwrap(), b"1");

    files.rename(&scratch.remote("two"), &scratch.remote("into/one"), true).await.unwrap();
    assert_eq!(std::fs::read(scratch.path("into/one")).unwrap(), b"2");
    assert_eq!(scratch.names(""), ["into"]);
}

#[tokio::test]
async fn remove_takes_a_file_or_an_empty_directory_and_nothing_more() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("remove");
    std::fs::write(scratch.path("file"), b"x").unwrap();
    std::fs::create_dir(scratch.path("empty")).unwrap();
    std::fs::create_dir(scratch.path("full")).unwrap();
    std::fs::write(scratch.path("full/inside"), b"x").unwrap();

    files.remove(&scratch.remote("file")).await.unwrap();
    files.remove(&scratch.remote("empty")).await.unwrap();
    let full = scratch.remote("full");
    assert_eq!(files.remove(&full).await.unwrap_err(), Error::NotEmpty { path: full });
    assert_eq!(scratch.names(""), ["full"]);
}

#[tokio::test]
async fn removing_a_tree_never_follows_a_link_out_of_it() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("tree");
    std::fs::create_dir_all(scratch.path("outside")).unwrap();
    std::fs::write(scratch.path("outside/keep"), b"precious").unwrap();
    std::fs::create_dir_all(scratch.path("tree/deeper/deepest")).unwrap();
    std::fs::write(scratch.path("tree/a"), b"x").unwrap();
    std::fs::write(scratch.path("tree/deeper/b"), b"x").unwrap();
    std::fs::write(scratch.path("tree/deeper/deepest/c"), b"x").unwrap();
    std::os::unix::fs::symlink(scratch.path("outside"), scratch.path("tree/deeper/escape"))
        .unwrap();

    let removed = files.remove_tree(&scratch.remote("tree")).await.unwrap();

    // Three files, one link, three directories counting the root.
    assert_eq!(removed, 7);
    assert_eq!(scratch.names(""), ["outside"]);
    assert_eq!(std::fs::read(scratch.path("outside/keep")).unwrap(), b"precious");
}

#[tokio::test]
async fn a_closed_session_says_so() {
    let Some(files) = files().await else { return };
    files.close().await;
    assert!(matches!(files.home().await.unwrap_err(), Error::Disconnected { .. }));
}

#[tokio::test]
async fn a_download_cancelled_partway_leaves_nothing_behind() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("download-partway");
    std::fs::write(scratch.path("remote.bin"), noise(4 * 1024 * 1024)).unwrap();
    let cancellation = CancellationToken::new();
    let cancel = cancellation.clone();

    let result = files
        .download(
            &scratch.remote("remote.bin"),
            &scratch.path("local.bin"),
            &cancellation,
            move |_| cancel.cancel(),
        )
        .await;

    assert_eq!(result.unwrap_err(), Error::Cancelled);
    assert_eq!(scratch.names(""), ["remote.bin"]);
}

#[tokio::test]
async fn an_upload_cancelled_partway_leaves_the_old_file_alone() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("upload-partway");
    std::fs::write(scratch.path("local.bin"), noise(4 * 1024 * 1024)).unwrap();
    std::fs::create_dir(scratch.path("remote")).unwrap();
    std::fs::write(scratch.path("remote/there.bin"), b"old").unwrap();
    let cancellation = CancellationToken::new();
    let cancel = cancellation.clone();

    let result = files
        .upload(
            &scratch.path("local.bin"),
            &scratch.remote("remote/there.bin"),
            true,
            &cancellation,
            move |_| cancel.cancel(),
        )
        .await;

    assert_eq!(result.unwrap_err(), Error::Cancelled);
    assert_eq!(scratch.names("remote"), ["there.bin"]);
    assert_eq!(std::fs::read(scratch.path("remote/there.bin")).unwrap(), b"old");
}
