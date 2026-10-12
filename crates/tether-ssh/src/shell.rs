//! A live shell on the far side.

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::error::SshError;

/// How big the remote terminal believes it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WindowSize {
    pub columns: u32,
    pub rows: u32,
}

impl WindowSize {
    pub fn new(columns: u32, rows: u32) -> Self {
        Self { columns, rows }
    }
}

impl Default for WindowSize {
    fn default() -> Self {
        Self { columns: 80, rows: 24 }
    }
}

/// Something the far side produced.
///
/// Bytes, not text: a shell emits whatever it likes, including invalid UTF-8
/// mid-sequence, and deciding what that means belongs to the terminal
/// (spec §8 — this crate never interprets the stream).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Output {
    Stdout(Vec<u8>),
    Stderr(Vec<u8>),
    /// The remote command ended with this status. More output may still
    /// arrive after it.
    Exited(u32),
}

/// An interactive shell with a pseudo-terminal attached.
///
/// Dropping it closes the channel.
pub struct Shell {
    pub(crate) channel: russh::Channel<russh::client::Msg>,
    pub(crate) size: WindowSize,
}

impl Shell {
    /// The size last requested. The far side may disagree until it processes
    /// the change, so this is what *we* asked for, not what it believes.
    pub fn size(&self) -> WindowSize {
        self.size
    }

    /// Sends bytes to the remote shell's input.
    pub async fn write(&self, bytes: impl Into<bytes::Bytes>) -> Result<(), SshError> {
        self.channel.data_bytes(bytes).await.map_err(Into::into)
    }

    /// Tells the far side the terminal changed size, so full-screen programs
    /// redraw and line editing wraps in the right place.
    pub async fn resize(&mut self, size: WindowSize) -> Result<(), SshError> {
        self.channel.window_change(size.columns, size.rows, 0, 0).await?;
        self.size = size;
        Ok(())
    }

    /// The next thing the far side produced, or `None` once the channel is
    /// finished.
    ///
    /// An async sequence rather than a callback (spec §13), and cancel-safe:
    /// abandoning this future loses nothing, because the message stays queued.
    pub async fn next_output(&mut self) -> Option<Output> {
        loop {
            match self.channel.wait().await? {
                russh::ChannelMsg::Data { data } => return Some(Output::Stdout(data.to_vec())),
                // Extended type 1 is stderr; SSH defines no others in practice,
                // and inventing a meaning for one would be guessing.
                russh::ChannelMsg::ExtendedData { data, ext: 1 } => {
                    return Some(Output::Stderr(data.to_vec()));
                }
                russh::ChannelMsg::ExitStatus { exit_status } => {
                    return Some(Output::Exited(exit_status));
                }
                // EOF says the far side has no more *data*. It does not say
                // the channel is over: SSH sends exit-status after EOF and
                // before close, so returning here would throw away the
                // status of every command that ran — measured: `exit 7`
                // surfaced as a lost connection.
                russh::ChannelMsg::Eof => continue,
                russh::ChannelMsg::Close => return None,
                // Window adjustments, unhandled requests and the rest are
                // protocol bookkeeping a consumer has no use for.
                _ => continue,
            }
        }
    }

    /// Closes the shell and tells the server so.
    pub async fn close(self) -> Result<(), SshError> {
        self.channel.eof().await?;
        self.channel.close().await.map_err(Into::into)
    }

    /// Copies bytes both ways between `socket` and this channel.
    ///
    /// The two directions run together. A tunnel that reads only one way
    /// until it finishes fills the window on the other and then waits for
    /// a window that never opens. `stop` ends both copies; dropping the
    /// channel is what tells the server the TCP connection is over.
    pub async fn tunnel(self, socket: TcpStream, mut stop: tokio::sync::watch::Receiver<bool>) {
        let (mut remote_read, remote_write) = self.channel.split();
        let (mut local_read, mut local_write) = socket.into_split();

        let outbound = async move {
            let mut buf = vec![0u8; 16 * 1024];
            loop {
                match local_read.read(&mut buf).await {
                    Ok(0) | Err(_) => {
                        let _ = remote_write.eof().await;
                        break;
                    }
                    Ok(n) => {
                        if remote_write.data_bytes(buf[..n].to_vec()).await.is_err() {
                            break;
                        }
                    }
                }
            }
        };

        let inbound = async move {
            loop {
                match remote_read.wait().await {
                    Some(russh::ChannelMsg::Data { data }) => {
                        if local_write.write_all(&data).await.is_err() {
                            break;
                        }
                    }
                    Some(russh::ChannelMsg::Eof | russh::ChannelMsg::Close) | None => break,
                    Some(_) => continue,
                }
            }
        };

        tokio::pin!(outbound);
        tokio::pin!(inbound);
        tokio::select! {
            _ = stop.wait_for(|stopped| *stopped) => {}
            _ = &mut outbound => {}
            _ = &mut inbound => {}
        }
    }
}
