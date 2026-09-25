//! Running a second command where a session's shell is already running.
//!
//! A terminal session is one byte stream. Some things a consumer wants —
//! listing what is running, attaching to a multiplexer — are a *second*
//! stream to the same machine, and the interesting part is that the question
//! "how do I start another command over there?" has two answers that look
//! nothing alike: another channel on an authenticated SSH session, or another
//! process on this computer.
//!
//! This is the seam that makes them one answer, for the same reason
//! [`Producer`] is: a feature built on top of it — tmux is the one that
//! exists — is then written once and works on both, instead of being a remote
//! feature with a local special case bolted on afterwards.
//!
//! No protocol is spoken here and none is understood. What crosses is a
//! command line and bytes (spec §8).
//!
//! [`Producer`]: crate::Producer

use std::sync::Arc;

use tether_local::{Command, Stream};
use tether_ssh::{Output, Session, Shell};
use tether_terminal::{Options, ScreenSize};

use crate::local::Local;
use crate::session::TerminalSession;
use crate::ssh_client::SshClient;

/// Why a command could not be run, or stopped being runnable.
///
/// A sentence, not a code, and for the same reason as everywhere else here:
/// which side answered and what number it used are diagnostic context, never
/// the shape a consumer matches on (spec §18).
#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
#[error("{cause}")]
pub struct ConnectionError {
    pub cause: String,
}

impl ConnectionError {
    pub(crate) fn new(cause: impl std::fmt::Display) -> Self {
        Self { cause: cause.to_string() }
    }
}

/// Everything a finished command left behind.
///
/// The two streams stay apart. A command whose output is *parsed* puts its
/// answer on one and its reason for failing on the other, and merging them
/// would hand a warning to a parser as data. (A [`Producer`] merges them, for
/// the opposite and equally good reason: a person is reading it.)
///
/// [`Producer`]: crate::Producer
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capture {
    /// The exit status, or `None` when a signal ended the program.
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Capture {
    pub fn succeeded(&self) -> bool {
        self.status == Some(0)
    }

    /// What the command answered, as text. Lossy on purpose: a command run
    /// for its answer is a command whose answer is text, and refusing the
    /// whole reply over one bad byte would be a worse failure than a
    /// replacement character.
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    /// Why it failed, in the command's own words, or a sentence of ours when
    /// it did not say.
    pub fn complaint(&self) -> String {
        let said = String::from_utf8_lossy(&self.stderr);
        let said = said.trim();
        if said.is_empty() { "The command failed.".to_owned() } else { said.to_owned() }
    }
}

/// A lease on whatever can run a command where a session's shell is running.
///
/// Cloneable, and cheap to clone, because it is a *lease* rather than a
/// resource: the remote arm shares one authenticated session, and the local
/// arm holds nothing at all — the right to start a process on this computer
/// was not granted by anybody and cannot be lost.
#[derive(Clone)]
pub enum Connection {
    /// The authenticated session the shell was opened on. A second command
    /// is a channel, which costs a round trip rather than a handshake.
    Remote(Arc<Session>),
    /// This machine.
    Local,
    /// An OpenSSH client, typically attached to a ControlMaster another
    /// process already authenticated. A second command is another `ssh`
    /// invocation, which the master serves without a handshake.
    OpenSsh(SshClient),
}

impl Connection {
    /// Runs `command` and waits for everything it had to say.
    ///
    /// `limit` bounds each stream. A command run for its answer has an
    /// expected size, and one that exceeds it is either the wrong command or
    /// a program in a loop — reading it to the end would answer a mistake by
    /// exhausting memory.
    pub async fn capture(&self, command: &str, limit: usize) -> Result<Capture, ConnectionError> {
        match self {
            Self::Remote(session) => {
                let mut channel = session.exec(command).await.map_err(ConnectionError::new)?;
                let mut capture = Capture { status: None, stdout: Vec::new(), stderr: Vec::new() };

                while let Some(output) = channel.next_output().await {
                    match output {
                        Output::Stdout(bytes) => capture.stdout.extend(bytes),
                        Output::Stderr(bytes) => capture.stderr.extend(bytes),
                        Output::Exited(status) => capture.status = Some(status as i32),
                    }
                    if capture.stdout.len() > limit || capture.stderr.len() > limit {
                        return Err(ConnectionError::new(format!(
                            "the command produced more than {limit} bytes"
                        )));
                    }
                }
                Ok(capture)
            }
            Self::Local => {
                let captured =
                    shell_command(command).capture(limit).await.map_err(ConnectionError::new)?;
                Ok(Capture {
                    status: captured.status,
                    stdout: captured.stdout,
                    stderr: captured.stderr,
                })
            }
            Self::OpenSsh(client) => {
                let client = client.clone().with_resolved_path().await;
                let captured =
                    client.exec(command).capture(limit).await.map_err(ConnectionError::new)?;
                Ok(Capture {
                    status: captured.status,
                    stdout: captured.stdout,
                    stderr: captured.stderr,
                })
            }
        }
    }

    /// Starts `command` and keeps its input and output open.
    pub async fn open(&self, command: &str) -> Result<Channel, ConnectionError> {
        match self {
            Self::Remote(session) => session
                .exec(command)
                .await
                .map(|shell| Channel::Remote(Some(shell)))
                .map_err(ConnectionError::new),
            Self::Local => Stream::start(&shell_command(command))
                .map(|stream| Channel::Local(Box::new(stream)))
                .map_err(ConnectionError::new),
            Self::OpenSsh(client) => {
                let client = client.clone().with_resolved_path().await;
                Stream::start(&client.exec(command))
                    .map(|stream| Channel::Local(Box::new(stream)))
                    .map_err(ConnectionError::new)
            }
        }
    }

    /// Opens a channel to the SFTP server where this connection is.
    ///
    /// Not a command line: on a remote session it is the `sftp` subsystem,
    /// so the server runs whichever program its administrator configured and
    /// no shell on the far side parses anything — a login banner printed by
    /// a profile script cannot land in the middle of the protocol. Through
    /// OpenSSH it is `ssh -s`, the same request. On this machine it is the
    /// `sftp-server` OpenSSH installed, started directly, which speaks the
    /// same protocol to the same client: files here and files there are one
    /// implementation, as a second command is.
    pub async fn sftp(&self) -> Result<Channel, ConnectionError> {
        match self {
            Self::Remote(session) => session
                .subsystem("sftp")
                .await
                .map(|shell| Channel::Remote(Some(shell)))
                .map_err(ConnectionError::new),
            Self::Local => {
                let server = local_sftp_server()
                    .ok_or_else(|| ConnectionError::new("no sftp-server on this machine"))?;
                // At home, as `sshd` starts it. Left alone it would start
                // wherever this process is, which for an application the
                // Finder launched is `/` — and `.` would be the whole disk.
                let mut command = Command::new(server);
                if let Some(home) = std::env::home_dir() {
                    command = command.directory(home);
                }
                Stream::start(&command)
                    .map(|stream| Channel::Local(Box::new(stream)))
                    .map_err(ConnectionError::new)
            }
            Self::OpenSsh(client) => {
                let client = client.clone().with_resolved_path().await;
                Stream::start(&client.subsystem("sftp"))
                    .map(|stream| Channel::Local(Box::new(stream)))
                    .map_err(ConnectionError::new)
            }
        }
    }

    /// Opens an interactive shell where this connection already is.
    ///
    /// Another channel on a remote session, another process on this machine —
    /// the same split as [`Self::open`], with a pseudo-terminal attached. A
    /// second terminal tab is this, not another handshake: the password and
    /// whatever else the server asked were spent getting the lease.
    pub async fn shell(
        &self,
        term: &str,
        size: ScreenSize,
        options: Options,
    ) -> Result<TerminalSession, ConnectionError> {
        match self {
            Self::Remote(session) => {
                let shell = session
                    .shell(term, tether_ssh::WindowSize::new(size.columns as u32, size.rows as u32))
                    .await
                    .map_err(ConnectionError::new)?;
                Ok(TerminalSession::start_with(shell, size, options, self.clone(), None, None))
            }
            Self::Local => Local::new()
                .term(term)
                .size(size)
                .options(options)
                .open()
                .await
                .map_err(ConnectionError::new),
            Self::OpenSsh(client) => client.clone().connect(term, size, options).await,
        }
    }
}

/// How a command line is run on this machine.
///
/// Through a login shell, and both halves of that matter. A *shell*, because
/// the caller wrote one string with the quoting a shell understands, and that
/// is what the remote arm hands to `sshd` as well — two arms that parse the
/// same string differently would be a seam that only looks like one. A
/// *login* shell, because a launched application inherits almost no `PATH`:
/// without the profile, a program the person installed themselves is simply
/// not found, and the failure reads as "you have no tmux" to someone looking
/// at tmux.
fn shell_command(command: &str) -> Command {
    Command::login_shell().arg("-c").arg(command)
}

/// Where OpenSSH installs its SFTP server: macOS first, then the Linux
/// distributions' layouts.
const LOCAL_SFTP_SERVERS: &[&str] = &[
    "/usr/libexec/sftp-server",
    "/usr/lib/openssh/sftp-server",
    "/usr/libexec/openssh/sftp-server",
    "/usr/lib/ssh/sftp-server",
];

/// This machine's SFTP server, if it has one. Found by path rather than by
/// `PATH`, because it is not a program anyone runs by name — `sshd` starts
/// it from a fixed location, and so do we.
fn local_sftp_server() -> Option<&'static str> {
    LOCAL_SFTP_SERVERS.iter().copied().find(|path| std::path::Path::new(path).is_file())
}

/// A command's input and output, held open.
///
/// One type over two transports, which is the whole point: whatever speaks a
/// protocol through this was written once.
pub enum Channel {
    /// Optional so that closing can *take* the channel. `Shell::close`
    /// consumes it — which is right, because a closed channel is not a thing
    /// — while everything that speaks a protocol holds its stream by `&mut`.
    Remote(Option<Shell>),
    Local(Box<Stream>),
}

impl Channel {
    /// The next bytes the command wrote, or `None` once it will write no more.
    ///
    /// Anything on standard error is a failure rather than more output. A
    /// command being spoken to in a protocol answers on standard output; what
    /// it puts on the other stream is a complaint, and feeding that to a
    /// parser as though it were an answer is how a protocol error becomes a
    /// mystery.
    pub async fn read(&mut self) -> Result<Option<Vec<u8>>, ConnectionError> {
        match self {
            Self::Remote(shell) => match ended(shell)?.next_output().await {
                Some(Output::Stdout(bytes)) => Ok(Some(bytes)),
                Some(Output::Stderr(bytes)) => {
                    Err(ConnectionError::new(String::from_utf8_lossy(&bytes).trim()))
                }
                _ => Ok(None),
            },
            Self::Local(stream) => stream.read().await.map_err(ConnectionError::new),
        }
    }

    pub async fn write(&mut self, bytes: &[u8]) -> Result<(), ConnectionError> {
        match self {
            Self::Remote(shell) => {
                ended(shell)?.write(bytes.to_vec()).await.map_err(ConnectionError::new)
            }
            Self::Local(stream) => stream.write(bytes).await.map_err(ConnectionError::new),
        }
    }

    /// Ends the command and releases what held it open.
    pub async fn close(&mut self) {
        match self {
            // Nowhere to report a failure to: the caller is finished either
            // way, and a server that will not acknowledge a close has already
            // stopped being reachable.
            Self::Remote(shell) => {
                if let Some(shell) = shell.take() {
                    let _ = shell.close().await;
                }
            }
            Self::Local(stream) => stream.close().await,
        }
    }
}

/// The channel, unless it has already been closed.
fn ended(shell: &mut Option<Shell>) -> Result<&mut Shell, ConnectionError> {
    shell.as_mut().ok_or_else(|| ConnectionError::new("the channel has been closed"))
}
