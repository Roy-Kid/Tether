//! Transactional, paged session archives. Paths and retention belong to the
//! caller; SQLite owns atomic updates, crash recovery, and bounded disk pages.
use rusqlite::{Connection, OpenFlags, params};
use std::{
    fs, io,
    path::Path,
    sync::{Arc, Mutex},
};
use tether_terminal::{HistoryEvent, HistoryRow};

const VERSION: i64 = 1;

#[derive(Clone, Debug)]
pub struct HistoryArchive(Arc<Mutex<Writer>>);

#[derive(Debug)]
struct Writer {
    db: Connection,
    limit: Option<u64>,
    error: Option<String>,
}

fn failure(error: impl std::fmt::Display) -> io::Error {
    io::Error::other(error.to_string())
}

impl HistoryArchive {
    pub fn create(directory: impl AsRef<Path>, limit: Option<u64>) -> io::Result<Self> {
        let directory = directory.as_ref();
        fs::create_dir(directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
        }
        let path = directory.join("history.sqlite");
        let db = Connection::open(&path).map_err(failure)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        }
        db.execute_batch(
            "PRAGMA auto_vacuum = FULL;
            PRAGMA secure_delete = ON;
            PRAGMA user_version = 1;
            CREATE TABLE lines (id INTEGER PRIMARY KEY, content BLOB NOT NULL);
            CREATE TABLE screen (id INTEGER PRIMARY KEY CHECK (id = 1), content BLOB NOT NULL);
            INSERT INTO screen VALUES (1, '[]');",
        )
        .map_err(failure)?;
        Self::writer(db, limit)
    }

    fn writer(db: Connection, limit: Option<u64>) -> io::Result<Self> {
        db.execute_batch(
            "PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;
            PRAGMA secure_delete = ON; PRAGMA cache_size = -1024;",
        )
        .map_err(failure)?;
        Ok(Self(Arc::new(Mutex::new(Writer { db, limit, error: None }))))
    }

    /// The saved screen becomes completed output when a new shell takes over.
    pub fn reopen(directory: impl AsRef<Path>, limit: Option<u64>) -> io::Result<Self> {
        let db = open_existing(directory.as_ref(), false)?;
        Self::writer(db, limit)
    }

    pub fn begin_session(&self) -> io::Result<()> {
        let mut writer = self.0.lock().expect("history lock poisoned");
        let data: Vec<u8> = writer
            .db
            .query_row("SELECT CAST(content AS BLOB) FROM screen WHERE id = 1", [], |row| {
                row.get(0)
            })
            .map_err(failure)?;
        let screen = decode_screen(&data)?;
        let end = screen
            .iter()
            .rposition(|row| row.cells.iter().any(|cell| !cell.is_blank()))
            .map_or(0, |i| i + 1);
        writer.append(screen.into_iter().take(end).map(HistoryEvent::Row).collect(), Vec::new())
    }

    pub fn write(&self, events: Vec<HistoryEvent>, screen: Vec<HistoryRow>) {
        let mut writer = self.0.lock().expect("history lock poisoned");
        if writer.error.is_some() {
            return;
        }
        if let Err(error) = writer.append(events, screen) {
            writer.error = Some(error.to_string());
        }
    }

    pub fn record_error(&self, error: String) {
        self.0.lock().expect("history lock poisoned").error = Some(error);
    }
    pub fn error(&self) -> Option<String> {
        self.0.lock().expect("history lock poisoned").error.clone()
    }

    pub fn tail(&self, count: usize) -> io::Result<Vec<HistoryRow>> {
        let writer = self.0.lock().expect("history lock poisoned");
        let mut statement = writer.db.prepare("SELECT content FROM (SELECT id, content FROM lines ORDER BY id DESC LIMIT ?1) ORDER BY id").map_err(failure)?;
        decode_rows(&mut statement, [count.min(100_000) as i64])
    }

    pub fn flush(&self) {
        let mut writer = self.0.lock().expect("history lock poisoned");
        if let Err(error) = writer.db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)") {
            writer.error = Some(error.to_string());
        }
    }
}

fn open_existing(directory: &Path, readonly: bool) -> io::Result<Connection> {
    let flags =
        if readonly { OpenFlags::SQLITE_OPEN_READ_ONLY } else { OpenFlags::SQLITE_OPEN_READ_WRITE };
    let db =
        Connection::open_with_flags(directory.join("history.sqlite"), flags).map_err(failure)?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0)).map_err(failure)?;
    if version != VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Unsupported session history version",
        ));
    }
    Ok(db)
}

/// Read a bounded page by row ID (not OFFSET, which would scan older rows).
/// Returns the next ID with each row so callers can page through Unlimited
/// histories without loading or counting the whole archive. IDs describe the
/// current snapshot; a viewer must restart pagination after a clear/reflow.
pub fn read_history(
    directory: impl AsRef<Path>,
    after: i64,
    count: usize,
) -> io::Result<Vec<(i64, HistoryRow)>> {
    let db = open_existing(directory.as_ref(), true)?;
    let mut query = db
        .prepare("SELECT id, content FROM lines WHERE id > ?1 ORDER BY id LIMIT ?2")
        .map_err(failure)?;
    let rows = query
        .query_map(params![after, count.min(10_000) as i64], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
        })
        .map_err(failure)?;
    rows.map(|r| {
        let (id, data) = r.map_err(failure)?;
        Ok((id, serde_json::from_slice::<StoredRow>(&data)?.unpack()?))
    })
    .collect()
}

pub fn read_screen(directory: impl AsRef<Path>) -> io::Result<Vec<HistoryRow>> {
    let db = open_existing(directory.as_ref(), true)?;
    let data: Vec<u8> = db
        .query_row("SELECT CAST(content AS BLOB) FROM screen WHERE id = 1", [], |r| r.get(0))
        .map_err(failure)?;
    decode_screen(&data)
}

fn decode_rows(
    statement: &mut rusqlite::Statement<'_>,
    parameters: impl rusqlite::Params,
) -> io::Result<Vec<HistoryRow>> {
    let rows = statement.query_map(parameters, |r| r.get::<_, Vec<u8>>(0)).map_err(failure)?;
    rows.map(|r| serde_json::from_slice::<StoredRow>(&r.map_err(failure)?)?.unpack()).collect()
}

impl Writer {
    fn append(&mut self, events: Vec<HistoryEvent>, screen: Vec<HistoryRow>) -> io::Result<()> {
        let transaction = self.db.transaction().map_err(failure)?;
        {
            let mut insert = transaction
                .prepare_cached("INSERT INTO lines(content) VALUES (?1)")
                .map_err(failure)?;
            for event in events {
                match event {
                    HistoryEvent::Clear => {
                        transaction.execute("DELETE FROM lines", []).map_err(failure)?;
                    }
                    HistoryEvent::Truncate(count) => {
                        transaction.execute("DELETE FROM lines WHERE id IN (SELECT id FROM lines ORDER BY id DESC LIMIT ?1)", [count as i64]).map_err(failure)?;
                    }
                    HistoryEvent::Row(row) => {
                        insert
                            .execute([serde_json::to_vec(&StoredRow::from(&row))?])
                            .map_err(failure)?;
                    }
                }
            }
        }
        if let Some(limit) = self.limit {
            transaction.execute("DELETE FROM lines WHERE id <= COALESCE((SELECT id FROM lines ORDER BY id DESC LIMIT 1 OFFSET ?1), -1)", [limit.min(i64::MAX as u64) as i64]).map_err(failure)?;
        }
        transaction
            .execute("UPDATE screen SET content = ?1 WHERE id = 1", [encode_screen(&screen)?])
            .map_err(failure)?;
        transaction.commit().map_err(failure)
    }
}

// Store style runs, not a copy of the same style for every terminal cell.
// Trailing default blanks are implied by `columns`, making idle screen
// checkpoints small while retaining coloured backgrounds and soft wraps.
#[derive(serde::Serialize, serde::Deserialize)]
struct StoredRow {
    columns: u16,
    wrapped: bool,
    runs: Vec<StoredRun>,
}
#[derive(serde::Serialize, serde::Deserialize)]
struct StoredRun {
    style: tether_terminal::Style,
    glyphs: Vec<(String, u8)>,
}
impl From<&HistoryRow> for StoredRow {
    fn from(row: &HistoryRow) -> Self {
        let end = row
            .cells
            .iter()
            .rposition(|c| c.style != tether_terminal::Style::default() || c.text != " ")
            .map_or(0, |i| i + 1);
        let mut runs: Vec<StoredRun> = Vec::new();
        for cell in &row.cells[..end] {
            if runs.last().is_none_or(|r| r.style != cell.style) {
                runs.push(StoredRun { style: cell.style, glyphs: Vec::new() });
            }
            runs.last_mut().unwrap().glyphs.push((cell.text.clone(), cell.width));
        }
        Self { columns: row.columns, wrapped: row.wrapped, runs }
    }
}
impl StoredRow {
    fn unpack(self) -> io::Result<HistoryRow> {
        let mut cells = Vec::new();
        let mut width = 0usize;
        for run in self.runs {
            for (text, w) in run.glyphs {
                if !(1..=2).contains(&w) || text.chars().any(char::is_control) {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "Invalid history cell"));
                }
                width += w as usize;
                if width > self.columns as usize {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Invalid history row width",
                    ));
                }
                cells.push(tether_terminal::Cell { text, width: w, style: run.style });
            }
        }
        cells.extend((width..self.columns as usize).map(|_| tether_terminal::Cell::blank()));
        Ok(HistoryRow { columns: self.columns, wrapped: self.wrapped, cells })
    }
}
fn encode_screen(rows: &[HistoryRow]) -> io::Result<Vec<u8>> {
    Ok(serde_json::to_vec(&rows.iter().map(StoredRow::from).collect::<Vec<_>>())?)
}
fn decode_screen(bytes: &[u8]) -> io::Result<Vec<HistoryRow>> {
    serde_json::from_slice::<Vec<StoredRow>>(bytes)?.into_iter().map(StoredRow::unpack).collect()
}
