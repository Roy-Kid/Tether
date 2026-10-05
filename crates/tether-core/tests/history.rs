use std::{
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};
use tether_core::{
    history::{HistoryArchive, read_history, read_screen},
    terminal::{Color, HistoryRow, NamedColor, Options, ScreenSize, Terminal},
};

static SERIAL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
struct ArchiveDir(PathBuf);
impl ArchiveDir {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!(
            "tether-history-{}-{}-{}",
            SERIAL.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        )))
    }
}
impl Drop for ArchiveDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn text(row: &HistoryRow) -> String {
    row.cells.iter().map(|c| c.text.as_str()).collect::<String>().trim_end().to_owned()
}
fn terminal(columns: u16, rows: u16, memory: usize) -> Terminal {
    let mut terminal = Terminal::with_options(
        ScreenSize::new(columns, rows),
        Options { scrollback_lines: memory },
    );
    terminal.record_history();
    terminal
}
fn commit(terminal: &mut Terminal, archive: &HistoryArchive) {
    archive.write(terminal.take_history_events(), terminal.history_screen());
    assert_eq!(archive.error(), None);
}
fn all(dir: &ArchiveDir) -> Vec<String> {
    let mut result: Vec<_> =
        read_history(&dir.0, 0, 10_000).unwrap().into_iter().map(|(_, r)| text(&r)).collect();
    result.extend(read_screen(&dir.0).unwrap().iter().map(text));
    while result.last().is_some_and(String::is_empty) {
        result.pop();
    }
    result
}

#[test]
fn unlimited_captures_a_burst_larger_than_memory_before_any_frame_is_requested() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut terminal = terminal(20, 3, 2);
    let output: String = (0..1000).map(|i| format!("line {i}\r\n")).collect();
    terminal.feed(output.as_bytes());
    commit(&mut terminal, &archive);
    assert_eq!(terminal.history_lines(), 2);
    assert_eq!(all(&dir), (0..1000).map(|i| format!("line {i}")).collect::<Vec<_>>());
    drop(archive);
    let reopened = HistoryArchive::reopen(&dir.0, None).unwrap();
    reopened.begin_session().unwrap();
    assert_eq!(
        reopened.tail(5).unwrap().iter().map(text).collect::<Vec<_>>(),
        (995..1000).map(|i| format!("line {i}")).collect::<Vec<_>>()
    );
}

#[test]
fn finite_retention_keeps_n_completed_rows_plus_the_screen_and_pages_by_id() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, Some(5)).unwrap();
    let mut terminal = terminal(20, 3, 2);
    for i in 0..25 {
        terminal.feed(format!("{i}\r\n").as_bytes());
        commit(&mut terminal, &archive);
    }
    assert_eq!(all(&dir), (18..25).map(|i| i.to_string()).collect::<Vec<_>>());
    let page = read_history(&dir.0, 0, 2).unwrap();
    let next = read_history(&dir.0, page.last().unwrap().0, 10).unwrap();
    assert_eq!(page.len() + next.len(), 5);
    assert_eq!(text(&next[0].1), "20");
}

#[test]
fn unicode_style_wraps_and_primary_screen_survive_alternate_screen() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut terminal = terminal(8, 3, 2);
    for byte in "\x1b[31;1m中文e\u{301}XYZ123\x1b[0m\r\nprompt>\r\n".as_bytes() {
        terminal.feed(&[*byte]);
    }
    commit(&mut terminal, &archive);
    let expected = all(&dir);
    terminal.feed(b"\x1b[?1049hTUI\r\nprivate\r\nredraw\r\n\x1b[?1049l");
    commit(&mut terminal, &archive);
    assert_eq!(all(&dir), expected);
    terminal.feed(b"\x1b[?1049hTUI");
    commit(&mut terminal, &archive);
    assert_eq!(all(&dir), expected);
    let saved = read_history(&dir.0, 0, 5).unwrap();
    let row = &saved[0].1;
    assert!(row.wrapped);
    assert!(row.cells[0].style.bold);
    assert_eq!(row.cells[0].style.foreground, Color::Named(NamedColor::Red));
    assert_eq!(row.cells[0].width, 2);
}

#[test]
fn resize_replaces_only_the_cached_tail_without_duplication_or_lost_rows() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut terminal = terminal(20, 3, 100);
    terminal.feed(b"one\r\ntwo\r\nthree\r\nfour\r\nfive");
    commit(&mut terminal, &archive);
    let expected = all(&dir);
    terminal.resize(ScreenSize::new(20, 5));
    commit(&mut terminal, &archive);
    assert_eq!(all(&dir), expected);
    terminal.resize(ScreenSize::new(20, 2));
    commit(&mut terminal, &archive);
    assert_eq!(all(&dir), expected);
    terminal.feed(b"\r\nsix\r\nseven");
    commit(&mut terminal, &archive);
    assert_eq!(all(&dir), ["one", "two", "three", "four", "five", "six", "seven"]);
}

#[test]
fn explicit_clear_also_erases_persisted_history() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut terminal = terminal(20, 2, 3);
    terminal.feed(b"old\r\nolder\r\ncurrent\x1b[3J");
    commit(&mut terminal, &archive);
    assert!(read_history(&dir.0, 0, 10).unwrap().is_empty());
    assert_eq!(all(&dir), ["older", "current"]);
}

#[test]
fn reopening_rejects_unknown_versions_without_modifying_the_file() {
    let dir = ArchiveDir::new();
    drop(HistoryArchive::create(&dir.0, None).unwrap());
    let db = rusqlite::Connection::open(dir.0.join("history.sqlite")).unwrap();
    db.execute_batch("PRAGMA user_version = 999").unwrap();
    assert!(HistoryArchive::reopen(&dir.0, None).is_err());
    assert_eq!(db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0)).unwrap(), 999);
}

#[tokio::test]
async fn a_session_records_before_its_first_byte_and_restores_without_writing_to_the_shell() {
    use tether_core::{Local, local_shell::Command};
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    fn print_line(text: &str) -> Command {
        if cfg!(windows) {
            Command::new("cmd.exe").arg("/d").arg("/c").arg(format!("echo {text}"))
        } else {
            Command::new("/bin/sh").arg("-c").arg(format!("printf '{text}\\n'"))
        }
    }
    let session = Local::running(print_line("hello history"))
        .history(Some(archive.clone()))
        .open()
        .await
        .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while session.ending().is_none() {
            session.changed().await;
        }
    })
    .await
    .unwrap();
    session.close().await.unwrap();
    assert!(all(&dir).iter().any(|row| row.contains("hello history")));
    let resumed = HistoryArchive::reopen(&dir.0, None).unwrap();
    let session =
        Local::running(print_line("new shell")).history(Some(resumed)).open().await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while session.ending().is_none() {
            session.changed().await;
        }
    })
    .await
    .unwrap();
    session.close().await.unwrap();
    let rows = all(&dir);
    assert_eq!(rows.iter().filter(|r| r.contains("hello history")).count(), 1);
    assert_eq!(rows.iter().filter(|r| r.contains("new shell")).count(), 1);
}

fn logical(dir: &ArchiveDir) -> String {
    let mut rows: Vec<_> =
        read_history(&dir.0, 0, 10_000).unwrap().into_iter().map(|(_, r)| r).collect();
    rows.extend(read_screen(&dir.0).unwrap());
    let mut text = String::new();
    for row in rows {
        for cell in row.cells {
            text.push_str(&cell.text);
        }
        if !row.wrapped {
            text.push('\n');
        }
    }
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[test]
fn narrow_reflow_keeps_evicted_history_and_does_not_lose_the_replaced_tail() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut terminal = terminal(20, 3, 3);
    for i in 0..20 {
        terminal.feed(format!("row-{i:02}-abcdefghij\r\n").as_bytes());
        commit(&mut terminal, &archive);
    }
    let before = logical(&dir);
    terminal.resize(ScreenSize::new(10, 3));
    commit(&mut terminal, &archive);
    assert_eq!(logical(&dir), before);
    terminal.feed(b"\x1b[?1049hTUI");
    terminal.resize(ScreenSize::new(8, 4));
    terminal.resize(ScreenSize::new(12, 2));
    terminal.feed(b"\x1b[?1049l");
    commit(&mut terminal, &archive);
    assert_eq!(logical(&dir), before);
}

#[test]
fn uncommitted_write_is_rolled_back_and_archive_has_private_permissions() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut terminal = terminal(20, 2, 10);
    terminal.feed(b"keep\r\nthis\r\ntext");
    commit(&mut terminal, &archive);
    let before = all(&dir);
    {
        let mut db = rusqlite::Connection::open(dir.0.join("history.sqlite")).unwrap();
        let tx = db.transaction().unwrap();
        tx.execute("DELETE FROM lines", []).unwrap();
        // An interrupted update never commits a partially cleared archive.
    }
    assert_eq!(all(&dir), before);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&dir.0).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(
            std::fs::metadata(dir.0.join("history.sqlite")).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[test]
fn tabs_at_the_wrap_boundary_are_captured_and_can_be_read_back() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut terminal = terminal(8, 1, 0);
    terminal.feed(b"a\tb\r\n12345678\tnext");
    commit(&mut terminal, &archive);
    let rows = all(&dir);
    assert!(rows.iter().any(|r| r == "12345678"));
    assert!(rows.iter().any(|r| r.starts_with('a')));
}

#[tokio::test]
async fn restored_display_never_becomes_pty_input_or_terminal_replies() {
    use std::sync::{Arc, Mutex};
    use tether_core::{Output, Producer, ProducerError, TerminalSession};
    struct Probe {
        output: tokio::sync::mpsc::Receiver<Output>,
        writes: Arc<Mutex<Vec<Vec<u8>>>>,
    }
    impl Producer for Probe {
        async fn write(&mut self, bytes: Vec<u8>) -> Result<(), ProducerError> {
            self.writes.lock().unwrap().push(bytes);
            Ok(())
        }
        async fn resize(&mut self, _: ScreenSize) -> Result<(), ProducerError> {
            Ok(())
        }
        async fn next_output(&mut self) -> Option<Output> {
            self.output.recv().await
        }
        async fn close(self) {}
    }
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut old = terminal(80, 24, 10);
    old.feed(b"\x1b[31mold output\r\n\x1b[6n");
    commit(&mut old, &archive);
    let writes = Arc::new(Mutex::new(Vec::new()));
    let (sender, output) = tokio::sync::mpsc::channel(1);
    let session = TerminalSession::start_recorded(
        Probe { output, writes: writes.clone() },
        ScreenSize::new(80, 24),
        Options { scrollback_lines: 10 },
        Some(archive),
    );
    tokio::task::yield_now().await;
    assert!(writes.lock().unwrap().is_empty());
    let visible = session.screen().text();
    assert!(visible.contains("old output"), "restored content must be visible without scrolling");
    assert!(visible.contains("Session restored"));
    // The frontend measures its actual viewport after opening the session.
    session.resize(ScreenSize::new(100, 30)).unwrap();
    assert!(session.screen().text().contains("old output"));
    sender.send(Output::Bytes(b"new output".to_vec())).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        while !session.screen().text().contains("new output") {
            session.changed().await;
        }
    })
    .await
    .unwrap();
    let visible = session.screen().text();
    assert!(visible.find("old output").unwrap() < visible.find("Session restored").unwrap());
    assert!(visible.find("Session restored").unwrap() < visible.find("new output").unwrap());
    session.resize(ScreenSize::new(10, 4)).unwrap();
    session.close().await.unwrap();
    assert!(writes.lock().unwrap().is_empty());
    assert_eq!(logical(&dir).matches("old output").count(), 1);
    assert_eq!(logical(&dir).matches("new output").count(), 1);
}

#[test]
fn a_failed_disk_transaction_preserves_the_previous_checkpoint_and_reports_failure() {
    let dir = ArchiveDir::new();
    let archive = HistoryArchive::create(&dir.0, None).unwrap();
    let mut terminal = terminal(20, 2, 10);
    terminal.feed(b"saved\r\nscreen");
    commit(&mut terminal, &archive);
    let before = all(&dir);
    let db = rusqlite::Connection::open(dir.0.join("history.sqlite")).unwrap();
    db.execute_batch("CREATE TRIGGER reject_write BEFORE INSERT ON lines BEGIN SELECT RAISE(FAIL, 'simulated storage failure'); END;").unwrap();
    terminal.feed(b"\r\nstill live");
    archive.write(terminal.take_history_events(), terminal.history_screen());
    assert!(archive.error().unwrap().contains("simulated storage failure"));
    assert_eq!(all(&dir), before);
    assert!(terminal.screen().text().contains("still live"));
}
