//! Native tmux bindings. The transport adapter is here, outside tether-tmux.
//!
//! One adapter, not two. tmux's control protocol runs over an ordered duplex
//! byte stream and does not care how it was obtained, so this speaks it over
//! [`tether_core::Channel`] — which is another SSH channel on a remote
//! session and another process on a local one. The tmux workspace above it
//! was written once and never learns which it got.
use crate::{CancellationToken, Resolved, ScreenFrame, TerminalInput, TetherError};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tether_core::{Channel, Connection};
use tether_tmux::{Action, Transport};

fn error(error: impl ToString) -> TetherError {
    TetherError::Protocol { cause: error.to_string() }
}

/// How much a command run for its answer may produce before it is refused.
const ANSWER_LIMIT: usize = 1024 * 1024;

/// How long such a command is given to answer.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(15);

struct Control(Channel);
#[async_trait::async_trait]
impl Transport for Control {
    async fn read(&mut self) -> tether_tmux::Result<Option<Vec<u8>>> {
        self.0.read().await.map_err(|e| tether_tmux::Error(e.to_string()))
    }
    async fn write(&mut self, bytes: &[u8]) -> tether_tmux::Result<()> {
        self.0.write(bytes).await.map_err(|e| tether_tmux::Error(e.to_string()))
    }
    async fn close(&mut self) {
        // The newline gives tmux a chance to notice and detach cleanly; the
        // close after it ends the channel whether or not that was written.
        let _ = tokio::time::timeout(Duration::from_secs(1), self.0.write(b"\n")).await;
        self.0.close().await;
    }
}

#[derive(uniffi::Object)]
pub struct RemoteConnection {
    pub(crate) inner: Connection,
}
/// A window discovered by listing, not by attaching. Listing is a capture;
/// it must not open a control client.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct TmuxListedWindow {
    pub id: u32,
    pub index: u32,
    pub name: String,
    pub active: bool,
    pub panes: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct TmuxSessionInfo {
    pub id: String,
    pub name: String,
    pub attached: bool,
    pub windows: Vec<TmuxListedWindow>,
}
/// Bounded output from a command on an authenticated connection.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CommandOutput {
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[uniffi::export(async_runtime = "tokio")]
impl RemoteConnection {
    /// Executes without creating a terminal or performing another authentication.
    /// Both output size and duration are bounded at this public boundary.
    pub async fn execute(
        &self,
        command: String,
        cancellation: Arc<CancellationToken>,
    ) -> Result<CommandOutput, TetherError> {
        tokio::select! {
            _ = cancellation.inner.cancelled() => Err(error("Cancelled")),
            result = tokio::time::timeout(ANSWER_TIMEOUT, self.inner.capture(&command, ANSWER_LIMIT)) => {
                let capture = result.map_err(|_| error("Command timed out"))?.map_err(error)?;
                Ok(CommandOutput { status: capture.status, stdout: capture.stdout, stderr: capture.stderr })
            }
        }
    }

    pub async fn tmux_sessions(
        &self,
        cancellation: Arc<CancellationToken>,
    ) -> Result<Vec<TmuxSessionInfo>, TetherError> {
        tokio::select! {
            _ = cancellation.inner.cancelled() => Err(error("Cancelled")),
            result = async {
                self.query("tmux -V").await?;
                // No server is an ordinary empty list. An absent binary was checked above.
                // `|` not tab: tmux 3.2 replaces C0 controls in `-F` output
                // with `_`, so a tab-separated listing arrives as `$28_0_ATV`
                // and parses as no sessions at all.
                let text = match self.query(
                    "tmux list-sessions -F '#{session_id}|#{session_attached}|#{session_name}'",
                )
                .await
                {
                    Ok(text) => text,
                    Err(TetherError::Protocol { cause })
                        if cause.contains("no server running")
                            || cause.contains("No such file or directory") =>
                    {
                        String::new()
                    }
                    Err(error) => return Err(error),
                };
                // Windows for every session, still a capture — not attach.
                // An empty listing on error: the session list above already
                // decided this call is answerable, and windows that cannot be
                // listed are shown as none rather than failing the whole view.
                let windows = self
                    .query(
                        "tmux list-windows -a -F '#{session_id}|#{window_id}|#{window_index}|#{window_active}|#{window_panes}|#{window_name}'",
                    )
                    .await
                    .unwrap_or_default();
                assemble_sessions(&text, &windows)
            } => result,
        }
    }
    /// Where tmux says a pane's program is — `#{pane_current_path}`, which
    /// tmux reads from the process itself, so it is known even when the
    /// shell in the pane reports nothing.
    pub async fn tmux_pane_directory(&self, pane_id: u32) -> Result<String, TetherError> {
        let text = self
            .query(&format!("tmux display-message -p -t %{pane_id} '#{{pane_current_path}}'"))
            .await?;
        let path = text.trim();
        if path.starts_with('/') && !path.contains(char::is_control) {
            Ok(path.to_owned())
        } else {
            Err(error(format!("tmux gave no directory for pane %{pane_id}")))
        }
    }
    pub async fn attach_tmux(
        &self,
        session_id: String,
        cancellation: Arc<CancellationToken>,
    ) -> Result<Arc<TmuxWorkspace>, TetherError> {
        validate_session(&session_id)?;
        let command = format!("tmux -C attach-session -t '{}'", session_id);
        tokio::select! {
            _ = cancellation.inner.cancelled() => Err(error("Cancelled")),
            channel = self.inner.open(&command) => {
                let channel = channel.map_err(error)?;
                Ok(Arc::new(TmuxWorkspace {
                    inner: tether_tmux::Workspace::start(Control(channel)),
                    _connection: self.inner.clone(),
                }))
            }
        }
    }
    pub async fn create_tmux(
        &self,
        name: String,
        directory: Option<String>,
        cancellation: Arc<CancellationToken>,
    ) -> Result<TmuxSessionInfo, TetherError> {
        let quoted = tether_tmux::quote(&name).map_err(error)?;
        if name.trim().is_empty() {
            return Err(error("Enter a session name"));
        }
        let start_directory = directory
            .map(|directory| tether_tmux::quote(&directory).map_err(error))
            .transpose()?;
        let directory_option = start_directory
            .map(|directory| format!("-c {directory} "))
            .unwrap_or_default();
        let command =
            format!("tmux new-session -d -P -F '#{{session_id}}' {directory_option}-s {quoted}");
        tokio::select! {
            _ = cancellation.inner.cancelled() => Err(error("Cancelled")),
            result = self.query(&command) => {
                let id = result?.trim().to_owned(); validate_session(&id)?;
                Ok(TmuxSessionInfo { id, name, attached: false, windows: Vec::new() })
            }
        }
    }
    pub async fn rename_tmux(&self, session_id: String, name: String) -> Result<(), TetherError> {
        validate_session(&session_id)?;
        self.query(&format!(
            "tmux rename-session -t '{}' {}",
            session_id,
            tether_tmux::quote(&name).map_err(error)?
        ))
        .await?;
        Ok(())
    }
    pub async fn end_tmux(&self, session_id: String) -> Result<(), TetherError> {
        validate_session(&session_id)?;
        self.query(&format!("tmux kill-session -t '{}'", session_id)).await?;
        Ok(())
    }
    /// Ends one window without attaching to its session. A window id is
    /// unique across the server, so it names the window on its own.
    pub async fn end_tmux_window(&self, window_id: u32) -> Result<(), TetherError> {
        self.query(&format!("tmux kill-window -t '@{window_id}'")).await?;
        Ok(())
    }

    /// Opens an interactive shell on this lease. No handshake: the connection
    /// is already authenticated, and a second terminal is another channel.
    pub async fn open_shell(
        &self,
        term: String,
        columns: u16,
        rows: u16,
        scrollback_lines: u32,
        cancellation: Arc<CancellationToken>,
    ) -> Result<Arc<crate::session::Session>, TetherError> {
        let size = tether_core::terminal::ScreenSize::new(columns, rows);
        let options =
            tether_core::terminal::Options { scrollback_lines: scrollback_lines as usize };
        tokio::select! {
            biased;
            _ = cancellation.inner.cancelled() => Err(TetherError::Cancelled),
            result = self.inner.shell(&term, size, options) => {
                let session = result.map_err(|error| TetherError::ShellRefused { cause: error.cause })?;
                Ok(crate::session::Session::wrap(session))
            }
        }
    }

    /// Finds the tmux session attached to a particular terminal, if any.
    pub async fn tmux_session_for_client(
        &self,
        tty: String,
    ) -> Result<Option<String>, TetherError> {
        let text = match self.query("tmux list-clients -F '#{client_tty}|#{session_id}'").await {
            Ok(text) => text,
            Err(TetherError::Protocol { cause })
                if cause.contains("no server running")
                    || cause.contains("no clients")
                    || cause.contains("No such file or directory") =>
            {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        for line in text.lines() {
            let Some((client_tty, session_id)) = line.split_once('|') else { continue };
            if client_tty == tty {
                validate_session(session_id)?;
                return Ok(Some(session_id.to_owned()));
            }
        }
        Ok(None)
    }
}
impl RemoteConnection {
    /// Runs one command for its answer, wherever this session's shell is.
    async fn query(&self, command: &str) -> Result<String, TetherError> {
        let captured =
            tokio::time::timeout(ANSWER_TIMEOUT, self.inner.capture(command, ANSWER_LIMIT))
                .await
                .map_err(|_| error("The command timed out"))?
                .map_err(error)?;

        if !captured.succeeded() {
            return Err(error(query_complaint(&captured)));
        }
        Ok(captured.text())
    }
}
fn validate_session(id: &str) -> Result<(), TetherError> {
    if !id.starts_with('$')
        || id.len() < 2
        || id.len() > 20
        || !id[1..].bytes().all(|b| b.is_ascii_digit())
    {
        return Err(error("Invalid tmux session identifier"));
    }
    Ok(())
}

fn tmux_number(value: &str) -> Result<u32, TetherError> {
    value.trim_start_matches(['%', '@', '$']).parse().map_err(|_| error("Invalid tmux identifier"))
}

fn query_complaint(captured: &tether_core::Capture) -> String {
    let said = captured.complaint();
    if said != "The command failed." {
        return said;
    }
    let stdout = captured.text();
    let stdout = stdout.trim();
    if stdout.is_empty() { said } else { stdout.to_owned() }
}

fn assemble_sessions(sessions: &str, windows: &str) -> Result<Vec<TmuxSessionInfo>, TetherError> {
    // Login banners and module notices land on the same stream as the listing
    // on some hosts. One unparseable line must not refuse the sessions that
    // did parse — that is how a MOTD becomes "could not load tmux".
    let mut by_session: HashMap<String, Vec<TmuxListedWindow>> = HashMap::new();
    for line in windows.lines().filter(|line| !line.is_empty()) {
        if let Ok((session_id, window)) = parse_listed_window(line.trim_end_matches('\r')) {
            by_session.entry(session_id).or_default().push(window);
        }
    }
    let listed: Vec<TmuxSessionInfo> = sessions
        .lines()
        .filter(|line| !line.is_empty())
        .filter_map(|line| parse_listed_session(line.trim_end_matches('\r')).ok())
        .map(|(id, name, attached)| {
            let mut windows = by_session.remove(&id).unwrap_or_default();
            windows.sort_by_key(|window| window.index);
            TmuxSessionInfo { id, name, attached, windows }
        })
        .collect();
    if listed.is_empty() && sessions.lines().any(|line| !line.is_empty()) {
        let sample = sessions.lines().find(|line| !line.is_empty()).unwrap_or("");
        return Err(error(format!("Invalid tmux session metadata: {sample}")));
    }
    Ok(listed)
}

/// Split a listing line. `|` is what we ask tmux for; tab is accepted so a
/// newer tmux that still emits C0 separators is not a second parser.
fn fields(line: &str, n: usize) -> Option<Vec<&str>> {
    for delim in ['|', '\t'] {
        if line.bytes().filter(|&b| b == delim as u8).count() + 1 >= n {
            let parts: Vec<&str> = line.splitn(n, delim).collect();
            if parts.len() == n {
                return Some(parts);
            }
        }
    }
    None
}

fn parse_listed_session(line: &str) -> Result<(String, String, bool), TetherError> {
    let parts = fields(line, 3).ok_or_else(|| error("Invalid tmux session metadata"))?;
    let id = parts[0];
    let attached = parts[1];
    let name = parts[2];
    validate_session(id)?;
    Ok((id.into(), name.into(), attached != "0"))
}

fn parse_listed_window(line: &str) -> Result<(String, TmuxListedWindow), TetherError> {
    let parts = fields(line, 6).ok_or_else(|| error("Invalid tmux window metadata"))?;
    let session_id = parts[0];
    let window_id = parts[1];
    let index = parts[2];
    let active = parts[3];
    let panes = parts[4];
    let name = parts[5];
    validate_session(session_id)?;
    Ok((
        session_id.into(),
        TmuxListedWindow {
            id: tmux_number(window_id)?,
            index: tmux_number(index)?,
            name: name.into(),
            active: active == "1",
            panes: tmux_number(panes)?,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_listing_is_empty() {
        assert_eq!(assemble_sessions("", "").unwrap(), Vec::new());
    }

    #[test]
    fn sessions_carry_windows_without_attaching() {
        let sessions = "$1\t1\tmolpy-molrs\n$2\t0\tmolpack\n";
        let windows = concat!(
            "$1\t@12\t1\t1\t1\tclaude\n",
            "$2\t@4\t0\t0\t1\tzsh\n",
            "$2\t@5\t1\t1\t2\tvim\n",
        );
        let listed = assemble_sessions(sessions, windows).unwrap();
        assert_eq!(
            listed,
            vec![
                TmuxSessionInfo {
                    id: "$1".into(),
                    name: "molpy-molrs".into(),
                    attached: true,
                    windows: vec![TmuxListedWindow {
                        id: 12,
                        index: 1,
                        name: "claude".into(),
                        active: true,
                        panes: 1,
                    }],
                },
                TmuxSessionInfo {
                    id: "$2".into(),
                    name: "molpack".into(),
                    attached: false,
                    windows: vec![
                        TmuxListedWindow {
                            id: 4,
                            index: 0,
                            name: "zsh".into(),
                            active: false,
                            panes: 1,
                        },
                        TmuxListedWindow {
                            id: 5,
                            index: 1,
                            name: "vim".into(),
                            active: true,
                            panes: 2,
                        },
                    ],
                },
            ]
        );
    }

    #[test]
    fn a_session_name_may_contain_spaces() {
        let listed =
            assemble_sessions("$3\t0\tmy session\n", "$3\t@1\t0\t1\t1\teditor two\n").unwrap();
        assert_eq!(listed[0].name, "my session");
        assert_eq!(listed[0].windows[0].name, "editor two");
    }

    #[test]
    fn windows_sort_by_index() {
        let listed = assemble_sessions(
            "$1\t0\tdev\n",
            "$1\t@9\t2\t0\t1\tc\n$1\t@7\t0\t1\t1\ta\n$1\t@8\t1\t0\t1\tb\n",
        )
        .unwrap();
        assert_eq!(listed[0].windows.iter().map(|w| w.index).collect::<Vec<_>>(), vec![0, 1, 2]);
    }

    #[test]
    fn a_listing_that_is_only_garbage_is_a_protocol_error() {
        assert!(assemble_sessions("not-a-session\n", "").is_err());
    }

    #[test]
    fn extra_lines_are_ignored() {
        let listed = assemble_sessions(
            "Welcome to the cluster\n$1\t0\tdev\nLast login: yesterday\n",
            "modules loaded\n$1\t@1\t0\t1\t1\tzsh\ngarbage\n",
        )
        .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "dev");
        assert_eq!(listed[0].windows[0].name, "zsh");
    }

    #[test]
    fn pipe_separated_listing_from_tmux_3_2() {
        // Arrhenius (tmux 3.2a) turns tabs in `-F` output into `_`.
        let listed = assemble_sessions(
            "$28|0|ATV\n$29|1|molpy-molrs\n",
            "$28|@30|0|1|1|zsh\n$29|@32|0|1|1|claude\n",
        )
        .unwrap();
        assert_eq!(listed[0].name, "ATV");
        assert_eq!(listed[1].name, "molpy-molrs");
        assert!(listed[1].attached);
        assert_eq!(listed[1].windows[0].name, "claude");
    }

    #[test]
    fn a_name_may_contain_the_delimiter() {
        let listed = assemble_sessions("$1|0|foo|bar\n", "$1|@1|0|1|1|a|b\n").unwrap();
        assert_eq!(listed[0].name, "foo|bar");
        assert_eq!(listed[0].windows[0].name, "a|b");
    }

    #[test]
    fn underscores_from_c0_replacement_are_not_sessions() {
        assert!(assemble_sessions("$28_0_ATV\n", "").is_err());
    }
}

#[derive(uniffi::Object)]
pub struct TmuxWorkspace {
    inner: tether_tmux::Workspace,
    /// Held for the workspace's lifetime. A remote workspace dies with the
    /// session its channel is on, so the session has to outlive it.
    _connection: Connection,
}
#[derive(uniffi::Record)]
pub struct TmuxWindowInfo {
    pub id: u32,
    pub name: String,
    pub active: bool,
    pub width: u16,
    pub height: u16,
}
#[derive(uniffi::Record)]
pub struct TmuxPaneFrame {
    pub id: u32,
    pub window: u32,
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    pub active: bool,
    pub visible: bool,
    pub frame: ScreenFrame,
}
#[derive(uniffi::Record)]
pub struct TmuxSnapshot {
    pub windows: Vec<TmuxWindowInfo>,
    pub panes: Vec<TmuxPaneFrame>,
    pub ended: Option<String>,
}
#[derive(uniffi::Enum)]
pub enum TmuxAction {
    NewWindow,
    SelectWindow { id: u32 },
    RenameWindow { id: u32, name: String },
    CloseWindow { id: u32 },
    SelectPane { id: u32 },
    Split { id: u32, horizontal: bool },
    ResizePane { id: u32, columns: u16, rows: u16 },
    ZoomPane { id: u32 },
    ClosePane { id: u32 },
    Resize { columns: u16, rows: u16 },
    RenameSession { name: String },
    EndSession,
}
#[uniffi::export(async_runtime = "tokio")]
impl TmuxWorkspace {
    pub fn snapshot(&self) -> TmuxSnapshot {
        let snapshot = self.inner.snapshot();
        TmuxSnapshot {
            ended: snapshot.ended,
            windows: snapshot
                .windows
                .into_iter()
                .map(|w| TmuxWindowInfo {
                    id: w.id,
                    name: w.name,
                    active: w.active,
                    width: w.width,
                    height: w.height,
                })
                .collect(),
            panes: snapshot
                .panes
                .into_iter()
                .map(|p| TmuxPaneFrame {
                    id: p.info.id,
                    window: p.info.window,
                    x: p.info.x,
                    y: p.info.y,
                    width: p.info.width,
                    height: p.info.height,
                    active: p.info.active,
                    visible: p.info.visible,
                    frame: ScreenFrame::of(&p.screen, String::new()),
                })
                .collect(),
        }
    }
    pub async fn await_change(&self) -> bool {
        self.inner.changed().await
    }
    /// What the text at a cell of a pane names, as `Session::link_at`.
    pub fn link_at(&self, pane: u32, row: u16, column: u16) -> Option<crate::TerminalLink> {
        self.inner
            .link_at(pane, tether_core::terminal::Position::new(row, column))
            .map(crate::TerminalLink::from)
    }
    /// The directory a pane's shell last reported, if it reports one.
    pub fn working_directory(&self, pane: u32) -> Option<String> {
        self.inner.working_directory(pane)
    }
    pub fn detach(&self) {
        self.inner.detach();
    }
    pub fn send(&self, pane: u32, input: TerminalInput) -> Result<(), TetherError> {
        match input.resolve() {
            Resolved::Encoded(input) => self.inner.send(pane, &input),
            Resolved::Literal(text) => self.inner.write(pane, text.into_bytes()),
        }
        .map_err(error)
    }
    pub async fn scroll(&self, pane: u32, lines: i32) -> Result<(), TetherError> {
        self.inner.scroll(pane, lines).await.map_err(error)
    }
    pub async fn perform(&self, action: TmuxAction) -> Result<(), TetherError> {
        let action = match action {
            TmuxAction::NewWindow => Action::NewWindow,
            TmuxAction::SelectWindow { id } => Action::SelectWindow(id),
            TmuxAction::RenameWindow { id, name } => Action::RenameWindow(id, name),
            TmuxAction::CloseWindow { id } => Action::CloseWindow(id),
            TmuxAction::SelectPane { id } => Action::SelectPane(id),
            TmuxAction::Split { id, horizontal } => Action::Split(id, horizontal),
            TmuxAction::ResizePane { id, columns, rows } => Action::ResizePane(id, columns, rows),
            TmuxAction::ZoomPane { id } => Action::ZoomPane(id),
            TmuxAction::ClosePane { id } => Action::ClosePane(id),
            TmuxAction::Resize { columns, rows } => Action::Resize(columns, rows),
            TmuxAction::RenameSession { name } => Action::RenameSession(name),
            TmuxAction::EndSession => Action::EndSession,
        };
        self.inner.perform(action).await.map_err(error)
    }
}
