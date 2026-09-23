//! Files through the surface a consumer sees: a session's lease, then
//! SFTP on it. Local, so it runs wherever OpenSSH's `sftp-server` is
//! installed, and takes the same path a remote session does from the lease
//! upward.
//!
//! Unix-only: OpenSSH's `sftp-server` install paths.
#![cfg(unix)]

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use tether_ffi::{
    CancellationToken, FileError, FileKind, LocalShell, RemoteFiles, TransferProgress, open_local,
};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("tether-ffi-files-{name}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self, relative: &str) -> String {
        self.0.join(relative).to_string_lossy().into_owned()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[derive(Default)]
struct Recorded(AtomicU64);

impl TransferProgress for Recorded {
    fn advanced(&self, bytes: u64) {
        self.0.store(bytes, Ordering::SeqCst);
    }
}

async fn files() -> Option<Arc<RemoteFiles>> {
    let session = open_local(LocalShell {
        directory: None,
        term: "xterm-256color".to_owned(),
        columns: 80,
        rows: 24,
        scrollback_lines: 100,
    })
    .await
    .expect("a local shell");
    let connection = session.connection().expect("a local session leases a connection");
    match connection.files(CancellationToken::new()).await {
        Ok(files) => Some(files),
        Err(error) => {
            assert!(
                std::env::var_os("TETHER_REQUIRE_SFTP").is_none(),
                "TETHER_REQUIRE_SFTP is set and files failed: {error}"
            );
            eprintln!("skipping: {error}");
            None
        }
    }
}

#[tokio::test]
async fn a_lease_lists_moves_and_copies_files() {
    let Some(files) = files().await else { return };
    let scratch = Scratch::new("roundtrip");
    std::fs::write(scratch.path("report.pdf"), b"%PDF-1.7 not really").unwrap();
    std::fs::create_dir(scratch.path("figures")).unwrap();

    assert!(files.is_local(), "a local session's files are this machine's");
    let listed = files.list(scratch.path(""), CancellationToken::new()).await.unwrap();
    let names: Vec<(&str, FileKind)> =
        listed.iter().map(|entry| (entry.name.as_str(), entry.kind)).collect();
    assert_eq!(names, [("figures", FileKind::Directory), ("report.pdf", FileKind::File)]);

    let progress = Arc::new(Recorded::default());
    let copied = files
        .download(
            scratch.path("report.pdf"),
            scratch.path("figures/copy.pdf"),
            Some(progress.clone()),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(copied, 19);
    assert_eq!(progress.0.load(Ordering::SeqCst), 19);

    files
        .upload(
            scratch.path("figures/copy.pdf"),
            scratch.path("report.pdf"),
            false,
            None,
            CancellationToken::new(),
        )
        .await
        .map(|_| ())
        .expect_err("an existing file is not replaced unless asked");

    files.rename(scratch.path("figures"), scratch.path("plots"), false).await.unwrap();
    assert_eq!(files.stat(scratch.path("plots/copy.pdf")).await.unwrap().size, 19);

    let removed = files.remove_tree(scratch.path("plots"), CancellationToken::new()).await.unwrap();
    assert_eq!(removed, 2);
    assert!(matches!(files.stat(scratch.path("plots")).await, Err(FileError::NotFound { .. })));
}

#[tokio::test]
async fn a_cancelled_listing_says_cancelled() {
    let Some(files) = files().await else { return };
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    let result = files.list("/".to_owned(), cancelled).await;
    assert!(matches!(result, Err(FileError::Cancelled)), "{result:?}");
}
