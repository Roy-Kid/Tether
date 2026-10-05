# Local session history

Each terminal tab can own a local archive, independent of its bounded in-memory
scrollback. The app defaults to 10,000 completed physical rows per session, or
Unlimited, plus a separate snapshot of the primary screen. Soft-wrap boundaries,
Unicode cell widths and styles are retained. Settings apply to newly opened or
restored sessions. Alternate-screen output is excluded; the primary screen is
saved before switching to a full-screen application.

The app owns `Application Support/Tether/SessionHistory`, an atomic `tabs.json`
manifest and a UUID directory for each retained archive. Each archive contains
`history.sqlite`. Open tabs keep their files; the latest 20 closed tabs keep
theirs. Eviction and host/account invalidation remove unreferenced files. The
directory is private to its owner and excluded from backups. These files do not
participate in identity/iCloud synchronization. Authentication secrets and raw
input are not recorded; content displayed by a shell is terminal output and is
saved as such.

The terminal layer captures completed rows at the upstream VT Handler boundary,
before the memory limit can evict them. It delegates all terminal semantics to
Alacritty/vte. Resizing replaces the affected cached tail transactionally, so
reflow and growing a screen do not duplicate historical rows. Core owns recording
and file I/O. Capture starts before the session pump, for local, SSH and reused
connections alike; Swift frame publication and tab visibility do not control it.

Rows are stored as style runs. Writes are batched, with screen checkpoints at
250 ms while content changes, and a final checkpoint at close/background/quit.
A crash may lose the last uncommitted interval, but committed screen/history
updates are atomic. A disk error stops archiving and is reported without closing
the terminal. Unlimited grows on disk; memory history and SQLite's page cache
stay bounded. `read_history` provides row-ID pagination for future history views.

Reopening a tab reuses its archive and starts a new shell/connection. The current
restore path warms only the bounded live scrollback cache with the most recent
saved rows; the full archive remains on disk. Recent restored content stays in
the visible screen, with the new shell starting below the restore separator.
Paging older archived content in
the UI is a separate restore-view task. Imported content consists of sanitized
text and generated SGR only, never raw terminal responses, OSC or shell input.
This is content restoration, not process resurrection. Open tabs left by an app
exit appear in the restore stack after relaunch; they do not auto-connect.

## Dependency decision

SQLite provides transactions, crash recovery, indexed pagination, and page reuse
without implementing a file database. `rusqlite` is the established Rust binding,
maintained by the rusqlite organization with multiple contributors, actively
released and widely used. It is infrastructure and does not dictate Tether's
public API. rusqlite/libsqlite3-sys are MIT; bundled SQLite is public domain.
The bundled feature gives macOS and iOS the same reproducible database engine.
Versions are pinned by Cargo.lock. See https://github.com/rusqlite/rusqlite.
