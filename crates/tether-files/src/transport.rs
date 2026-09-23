//! The byte stream SFTP is spoken over, and the bridge onto it.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

use crate::error::Result;

/// How much may be in flight between the protocol and the transport.
///
/// Matches the client's largest packet, so one reply never has to wait on
/// the bridge to make room for its own tail.
const WINDOW: usize = 256 * 1024;

/// An ordered duplex byte stream. No SSH or process types cross this boundary.
///
/// `read` must be cancel-safe: the bridge waits on it and on the protocol at
/// once, and drops whichever did not finish first.
#[async_trait::async_trait]
pub trait Transport: Send + 'static {
    /// The next bytes from the server, or `None` once it will send no more.
    async fn read(&mut self) -> Result<Option<Vec<u8>>>;
    async fn write(&mut self, bytes: &[u8]) -> Result<()>;
    async fn close(&mut self);
}

/// Gives the protocol a tokio stream, and moves its bytes to and from
/// `transport` until either side ends.
///
/// The client wants `AsyncRead + AsyncWrite`; a lease hands out a message
/// transport. Rather than implement poll-level I/O over a channel that is
/// itself async, the two meet across an in-memory pipe, and one task carries
/// bytes each way. `alive` goes false when that task stops, which is how a
/// failed request is told apart from a session that has ended.
pub(crate) fn bridge(transport: impl Transport, alive: Arc<AtomicBool>) -> DuplexStream {
    let (ours, theirs) = tokio::io::duplex(WINDOW);
    tokio::spawn(carry(transport, theirs, alive));
    ours
}

async fn carry(mut transport: impl Transport, stream: DuplexStream, alive: Arc<AtomicBool>) {
    let (mut from_client, mut to_client) = tokio::io::split(stream);
    let mut buffer = vec![0u8; WINDOW];

    loop {
        tokio::select! {
            read = transport.read() => match read {
                Ok(Some(bytes)) => {
                    if to_client.write_all(&bytes).await.is_err() {
                        break;
                    }
                }
                Ok(None) | Err(_) => break,
            },
            read = from_client.read(&mut buffer) => match read {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if transport.write(&buffer[..n]).await.is_err() {
                        break;
                    }
                }
            },
        }
    }

    alive.store(false, Ordering::SeqCst);
    // Ends the client's reads too, so a request in flight fails now rather
    // than at its timeout.
    let _ = to_client.shutdown().await;
    transport.close().await;
}
