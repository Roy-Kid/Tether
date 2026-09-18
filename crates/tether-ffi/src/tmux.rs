//! Native tmux bindings. The SSH adapter is here, outside tether-tmux.
use crate::{CancellationToken, Resolved, ScreenFrame, TerminalInput, TetherError};
use std::sync::Arc;
use std::time::Duration;
use tether_core::ssh::{Output, Shell};
use tether_tmux::{Action, Transport};

fn error(error: impl ToString) -> TetherError {
    TetherError::Protocol { cause: error.to_string() }
}

struct Channel(Shell);
#[async_trait::async_trait]
impl Transport for Channel {
    async fn read(&mut self) -> tether_tmux::Result<Option<Vec<u8>>> {
        match self.0.next_output().await {
            Some(Output::Stdout(bytes)) => Ok(Some(bytes)),
            Some(Output::Stderr(bytes)) => {
                Err(tether_tmux::Error(String::from_utf8_lossy(&bytes).into()))
            }
            _ => Ok(None),
        }
    }
    async fn write(&mut self, bytes: &[u8]) -> tether_tmux::Result<()> {
        self.0.write(bytes.to_vec()).await.map_err(|e| tether_tmux::Error(e.to_string()))
    }
    async fn close(&mut self) {
        // Dropping the channel after this method closes it even if detach cannot be written.
        let _ = tokio::time::timeout(Duration::from_secs(1), self.0.write(b"\n".to_vec())).await;
    }
}

#[derive(uniffi::Object)]
pub struct RemoteConnection {
    pub(crate) inner: Arc<tether_core::ssh::Session>,
}
#[derive(Clone, uniffi::Record)]
pub struct TmuxSessionInfo {
    pub id: String,
    pub name: String,
}
#[uniffi::export(async_runtime = "tokio")]
impl RemoteConnection {
    pub async fn tmux_sessions(
        &self,
        cancellation: Arc<CancellationToken>,
    ) -> Result<Vec<TmuxSessionInfo>, TetherError> {
        tokio::select! {
            _ = cancellation.inner.cancelled() => Err(error("Cancelled")),
            result = async {
                self.query("tmux -V").await?;
                // No server is an ordinary empty list. An absent binary was checked above.
                let text = match self.query("tmux list-sessions -F '#{session_id} #{session_name}'").await {
                    Ok(text) => text,
                    Err(TetherError::Protocol { cause }) if cause.contains("no server running") || cause.contains("No such file or directory") => String::new(),
                    Err(error) => return Err(error),
                };
                text.lines().map(|line| {
                    let (id, name) = line.split_once(' ').ok_or_else(|| error("Invalid tmux session metadata"))?;
                    validate_session(id)?;
                    Ok(TmuxSessionInfo { id: id.into(), name: name.into() })
                }).collect()
            } => result,
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
            channel = self.inner.exec(&command) => {
                Ok(Arc::new(TmuxWorkspace { inner: tether_tmux::Workspace::start(Channel(channel?)), _connection: self.inner.clone() }))
            }
        }
    }
    pub async fn create_tmux(
        &self,
        name: String,
        cancellation: Arc<CancellationToken>,
    ) -> Result<TmuxSessionInfo, TetherError> {
        let quoted = tether_tmux::quote(&name).map_err(error)?;
        if name.trim().is_empty() {
            return Err(error("Enter a session name"));
        }
        let command = format!("tmux new-session -d -P -F '#{{session_id}}' -s {quoted}");
        tokio::select! {
            _ = cancellation.inner.cancelled() => Err(error("Cancelled")),
            result = self.query(&command) => {
                let id = result?.trim().to_owned(); validate_session(&id)?;
                Ok(TmuxSessionInfo { id, name })
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
}
impl RemoteConnection {
    async fn query(&self, command: &str) -> Result<String, TetherError> {
        tokio::time::timeout(Duration::from_secs(15), async {
            let mut channel = self.inner.exec(command).await?;
            let mut stdout = Vec::new();
            let mut stderr = Vec::new();
            let mut status = None;
            while let Some(output) = channel.next_output().await {
                match output {
                    Output::Stdout(bytes) => stdout.extend(bytes),
                    Output::Stderr(bytes) => stderr.extend(bytes),
                    Output::Exited(code) => status = Some(code),
                }
                if stdout.len() + stderr.len() > 1024 * 1024 {
                    return Err(error("Command output exceeds limit"));
                }
            }
            if status != Some(0) {
                return Err(error(if stderr.is_empty() {
                    "Remote command failed".into()
                } else {
                    String::from_utf8_lossy(&stderr).into_owned()
                }));
            }
            Ok(String::from_utf8_lossy(&stdout).into_owned())
        })
        .await
        .map_err(|_| error("Remote command timed out"))?
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

#[derive(uniffi::Object)]
pub struct TmuxWorkspace {
    inner: tether_tmux::Workspace,
    _connection: Arc<tether_core::ssh::Session>,
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
