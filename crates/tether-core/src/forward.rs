//! A TCP port on the far side, reached from this machine.
//!
//! `ssh -L` in the shape the rest of a lease already has. The far side is
//! asked, per accepted connection, to open TCP to its own loopback — a
//! direct-tcpip channel on an authenticated session, `ssh -W` through a
//! ControlMaster, and nothing at all when the shell is already here.
//! Listening and the copy stay on this side of the FFI boundary: a page
//! loaded through the tunnel is not a stream of UniFFI calls.

use std::net::Ipv4Addr;

use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;

use tether_local::Stream;
use tether_ssh::Shell;

use crate::connection::{Connection, ConnectionError};

/// How many ports past the one asked for are tried when it is taken.
const BIND_ATTEMPTS: u16 = 50;

/// A local listener, or the note that the port was already on this machine.
///
/// Dropping it closes the listener and the connections it accepted.
pub struct Listener {
    local_port: u16,
    already_local: bool,
    stop: watch::Sender<bool>,
}

impl std::fmt::Debug for Listener {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Listener")
            .field("local_port", &self.local_port)
            .field("already_local", &self.already_local)
            .finish()
    }
}

impl Listener {
    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    /// The shell is on this machine, so nothing was bound. The port in
    /// [`Self::local_port`] is the one the program is already listening on.
    pub fn already_local(&self) -> bool {
        self.already_local
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
    }
}

impl Connection {
    /// Which authenticated session this lease belongs to.
    ///
    /// Equal for every clone of one session, and different after a redial.
    /// A local shell has no session to distinguish. An OpenSSH client is
    /// identified by the target it was aimed at, which is what the master
    /// is keyed on.
    pub fn lease_id(&self) -> u64 {
        match self {
            // Session ids count up from 1 and do not use the high bit.
            Self::Remote(session) => session.id(),
            Self::Local => 0,
            Self::OpenSsh(client) => client.lease_id() | (1_u64 << 63),
        }
    }

    /// Listens on `127.0.0.1` and connects each accepted socket to
    /// `127.0.0.1:port` where this lease's shell is running.
    ///
    /// `port` itself is tried first. When it is already taken, the next
    /// free port is. A local shell does not listen: the program is already
    /// on this machine, and a second listener would only hide it.
    pub async fn listen(&self, port: u16) -> Result<Listener, ConnectionError> {
        if port < 1024 {
            return Err(ConnectionError::new("ports below 1024 are not forwarded"));
        }
        if matches!(self, Self::Local) {
            let (stop, _) = watch::channel(false);
            return Ok(Listener { local_port: port, already_local: true, stop });
        }

        let (listener, local_port) = bind_near(port).await?;
        let (stop, watch_stop) = watch::channel(false);
        let connection = self.clone();
        tokio::spawn(async move {
            accept_loop(listener, connection, port, watch_stop).await;
        });
        Ok(Listener { local_port, already_local: false, stop })
    }

    /// One TCP connection to loopback on the far side.
    async fn open_tcp(&self, port: u16) -> Result<Pipe, ConnectionError> {
        match self {
            Self::Remote(session) => {
                // Vite and other dev servers often listen on [::1] only.
                // A v4 dial is refused, the channel never opens, and the
                // browser sees the local listener drop the socket.
                let mut last = None;
                for host in ["127.0.0.1", "::1"] {
                    match session.direct_tcpip(host, port).await {
                        Ok(shell) => return Ok(Pipe::Remote(shell)),
                        Err(error) => last = Some(error),
                    }
                }
                Err(ConnectionError::new(last.expect("a loopback address was tried")))
            }
            Self::Local => TcpStream::connect((Ipv4Addr::LOCALHOST, port))
                .await
                .map(Pipe::Socket)
                .map_err(ConnectionError::new),
            Self::OpenSsh(client) => {
                let client = client.clone().with_resolved_path().await;
                Stream::start(&client.forward_stdio(port))
                    .map(Pipe::Process)
                    .map_err(ConnectionError::new)
            }
        }
    }
}

enum Pipe {
    Remote(Shell),
    Socket(TcpStream),
    Process(Stream),
}

impl Pipe {
    async fn tunnel(self, socket: TcpStream, stop: watch::Receiver<bool>) {
        match self {
            Self::Remote(shell) => shell.tunnel(socket, stop).await,
            Self::Socket(remote) => copy_sockets(socket, remote, stop).await,
            Self::Process(stream) => copy_process(stream, socket, stop).await,
        }
    }
}

async fn accept_loop(
    listener: TcpListener,
    connection: Connection,
    remote_port: u16,
    mut stop: watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            changed = stop.changed() => {
                if changed.is_err() || *stop.borrow() {
                    break;
                }
            }
            accepted = listener.accept() => {
                let Ok((socket, _)) = accepted else { break };
                let connection = connection.clone();
                let stop = stop.clone();
                tokio::spawn(async move {
                    if let Ok(pipe) = connection.open_tcp(remote_port).await {
                        pipe.tunnel(socket, stop).await;
                    }
                });
            }
        }
    }
}

/// Binds `127.0.0.1:preferred`, or the next free port above it.
async fn bind_near(preferred: u16) -> Result<(TcpListener, u16), ConnectionError> {
    let mut candidate = preferred;
    for _ in 0..BIND_ATTEMPTS {
        match TcpListener::bind((Ipv4Addr::LOCALHOST, candidate)).await {
            Ok(listener) => return Ok((listener, candidate)),
            Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => {
                candidate = match candidate.checked_add(1) {
                    Some(next) => next,
                    None => break,
                };
            }
            Err(error) => return Err(ConnectionError::new(error)),
        }
    }
    Err(ConnectionError::new(format!("no free local port at or above {preferred}")))
}

async fn copy_sockets(left: TcpStream, right: TcpStream, mut stop: watch::Receiver<bool>) {
    let (mut left_read, mut left_write) = left.into_split();
    let (mut right_read, mut right_write) = right.into_split();
    let outbound = async move {
        let _ = tokio::io::copy(&mut left_read, &mut right_write).await;
    };
    let inbound = async move {
        let _ = tokio::io::copy(&mut right_read, &mut left_write).await;
    };
    tokio::pin!(outbound);
    tokio::pin!(inbound);
    tokio::select! {
        _ = stop.wait_for(|stopped| *stopped) => {}
        _ = &mut outbound => {}
        _ = &mut inbound => {}
    }
}

async fn copy_process(stream: Stream, socket: TcpStream, mut stop: watch::Receiver<bool>) {
    let (mut child, stdin, mut stdout, mut stderr) = stream.into_stdio();
    let (mut socket_read, mut socket_write) = socket.into_split();
    let outbound = async move {
        if let Some(mut stdin) = stdin {
            let _ = tokio::io::copy(&mut socket_read, &mut stdin).await;
        }
    };
    let inbound = async move {
        let _ = tokio::io::copy(&mut stdout, &mut socket_write).await;
    };
    // Standard error ending is not the tunnel ending. `ssh -W` closes it
    // at once when it has nothing to say, and treating that as "the copy
    // is finished" drops the connection before the first byte comes back.
    let errors = async move {
        if let Some(stderr) = stderr.as_mut() {
            let mut sink = tokio::io::sink();
            let _ = tokio::io::copy(stderr, &mut sink).await;
        }
        std::future::pending::<()>().await
    };
    tokio::pin!(outbound);
    tokio::pin!(inbound);
    tokio::pin!(errors);
    tokio::select! {
        _ = stop.wait_for(|stopped| *stopped) => {}
        _ = &mut outbound => {}
        _ = &mut inbound => {}
        _ = &mut errors => {}
    }
    let _ = child.start_kill();
    let _ = child.wait().await;
}
