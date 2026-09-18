//! A live session, as a Swift consumer holds it.
//!
//! The object is a handle, never a pointer: UniFFI owns the allocation and a
//! consumer holds a reference-counted proxy (spec §13). Nothing here can
//! panic across the seam — every fallible path returns [`TetherError`], and
//! the lock guards are scoped so a poisoned lock cannot unwind into Swift.

use std::sync::Arc;

use tether_core::terminal::{Options, ScreenSize, Scroll};
use tether_core::{Credential, Dial, Ending, TerminalSession};

use crate::input::{Resolved, TerminalInput};
use crate::screen::ScreenFrame;
use crate::{AuthPrompt, InteractivePrompter, TetherError};

/// What a host key looks like to an application being asked to trust it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HostIdentity {
    pub host: String,
    pub port: u16,
    pub algorithm: String,
    /// The `SHA256:…` form a person compares against what their
    /// administrator published.
    pub fingerprint: String,
}

/// Asks the application whether a host may be talked to.
///
/// Upward, like the prompter, and for the same reason: only the application
/// knows what it has stored and what it may ask a person. It is called
/// during the handshake, before any credential exists on the wire — which is
/// the point of asking at all (spec §18).
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait HostTrust: Send + Sync {
    async fn trusts(&self, host: HostIdentity) -> bool;
}

/// Adapts the foreign trait to the one `tether-ssh` defines.
struct ForeignVerifier(Arc<dyn HostTrust>);

#[async_trait::async_trait]
impl tether_core::ssh::HostVerifier for ForeignVerifier {
    async fn verify(
        &self,
        endpoint: &tether_core::ssh::Endpoint,
        key: &tether_core::ssh::HostKey,
    ) -> tether_core::ssh::Verdict {
        let identity = HostIdentity {
            host: endpoint.host.clone(),
            port: endpoint.port,
            algorithm: key.algorithm.clone(),
            fingerprint: key.fingerprint.clone(),
        };
        if self.0.trusts(identity).await {
            tether_core::ssh::Verdict::Trusted
        } else {
            tether_core::ssh::Verdict::Rejected
        }
    }
}

/// Adapts the foreign prompter to the one `tether-ssh` defines.
struct ForeignPrompter(Arc<dyn InteractivePrompter>);

#[async_trait::async_trait]
impl tether_core::ssh::Prompter for ForeignPrompter {
    async fn answer(&self, challenge: &tether_core::ssh::Challenge) -> Option<Vec<String>> {
        let prompts = challenge
            .prompts
            .iter()
            .map(|prompt| AuthPrompt { text: prompt.text.clone(), echo: prompt.echo })
            .collect();

        let answers = self.0.answer(challenge.instruction.clone(), prompts).await;

        // An empty vector is how the foreign side says "the person declined".
        // Declining is a decision, not a rejected credential (spec §10).
        if answers.is_empty() { None } else { Some(answers) }
    }
}

/// A credential to offer, in the order they are given.
#[derive(uniffi::Enum)]
pub enum Secret {
    Password {
        password: String,
    },
    /// PEM text, so a key held in a keychain item never has to be written to
    /// a file to be used.
    PrivateKey {
        pem: String,
        passphrase: Option<String>,
    },
    /// Answers whatever the server asks, for as many rounds as it asks.
    Interactive {
        prompter: Arc<dyn InteractivePrompter>,
    },
}

/// Where to connect and as whom.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Destination {
    pub host: String,
    pub port: u16,
    pub user: String,
    /// What the far side will see in `$TERM`. It decides which sequences
    /// remote programs emit, so it must describe what this frontend can
    /// actually draw.
    pub term: String,
    pub columns: u16,
    pub rows: u16,
    pub scrollback_lines: u32,
}

/// Connects, authenticates and opens a shell.
///
/// Async all the way: a handshake is network-bound and a prompt is
/// person-bound, and neither may block a UI thread (spec §13).
///
/// `async_runtime = "tokio"` is load-bearing, not decoration. Without it
/// UniFFI polls the future on its own executor, where there is no reactor —
/// and the first socket this touches panics with "there is no reactor
/// running". It reaches a consumer as an opaque `rustPanic`, so the cost of
/// forgetting it is a crash with no useful error.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect(
    destination: Destination,
    trust: Arc<dyn HostTrust>,
    secrets: Vec<Secret>,
) -> Result<Arc<Session>, TetherError> {
    let size = ScreenSize::new(destination.columns, destination.rows);

    let credentials = secrets
        .into_iter()
        .map(|secret| match secret {
            Secret::Password { password } => Credential::Password(password),
            Secret::PrivateKey { pem, passphrase } => Credential::PrivateKey { pem, passphrase },
            Secret::Interactive { prompter } => {
                Credential::Interactive(Arc::new(ForeignPrompter(prompter)))
            }
        })
        .collect();

    let session = Dial::new(
        tether_core::ssh::Endpoint::new(destination.host, destination.port),
        destination.user,
    )
    .verifier(Arc::new(ForeignVerifier(trust)))
    .term(destination.term)
    .size(size)
    .options(Options { scrollback_lines: destination.scrollback_lines as usize })
    .connect(credentials)
    .await?;

    Ok(Arc::new(Session { inner: session }))
}

/// Cancellation-aware entry point; the original connect remains source compatible.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect_cancellable(
    destination: Destination,
    trust: Arc<dyn HostTrust>,
    secrets: Vec<Secret>,
    cancellation: Arc<crate::CancellationToken>,
) -> Result<Arc<Session>, TetherError> {
    tokio::select! {
        biased;
        _ = cancellation.inner.cancelled() => Err(TetherError::Cancelled),
        result = connect(destination, trust, secrets) => result,
    }
}

/// Where to put the viewport over the scrollback.
///
/// Named by intent, not by line arithmetic: how much a page is depends on the
/// screen, and a frontend that computed it would have to ask for the size and
/// could get a different answer than the engine uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScrollTo {
    /// Positive goes back into history, negative comes forward.
    Lines {
        count: i32,
    },
    PageUp,
    PageDown,
    Oldest,
    Live,
}

/// Why a session stopped.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SessionEnding {
    Exited { status: u32 },
    Closed,
    Lost { cause: String },
}

/// A live terminal session.
#[derive(uniffi::Object)]
pub struct Session {
    inner: TerminalSession,
}

/// Tokio again, for the same reason: `await_change` parks on a watch channel
/// that the pump task wakes, and the pump only exists inside a runtime.
#[uniffi::export(async_runtime = "tokio")]
impl Session {
    pub fn connection(&self) -> Option<Arc<crate::RemoteConnection>> {
        self.inner.connection().map(|inner| Arc::new(crate::RemoteConnection { inner }))
    }

    /// Everything needed to draw the screen once.
    pub fn frame(&self) -> ScreenFrame {
        ScreenFrame::of(&self.inner.screen(), self.inner.title())
    }

    /// Waits until the screen changed, returning `false` once the session has
    /// ended and never will again.
    ///
    /// A frontend's repaint loop is `while await session.awaitChange() { … }`:
    /// it costs nothing while the screen is still, and wakes on the first
    /// byte. Polling on a timer would either lag or burn a core.
    pub async fn await_change(&self) -> bool {
        self.inner.changed().await
    }

    /// Sends something the person did.
    ///
    /// Encoding happens on the Rust side, against the modes the *remote*
    /// program set — which is why a frontend sends a key rather than bytes
    /// (spec §12).
    pub fn send(&self, input: TerminalInput) -> Result<(), TetherError> {
        match input.resolve() {
            Resolved::Encoded(input) => self.inner.send(&input).map_err(Into::into),
            // Nothing to send is not an error: a key with no text and no
            // encoding is a key this terminal has no bytes for.
            Resolved::Literal(text) if text.is_empty() => Ok(()),
            Resolved::Literal(text) => self.inner.write(text.into_bytes()).map_err(Into::into),
        }
    }

    /// Moves the viewport over the scrollback.
    ///
    /// Nothing to report: the engine clamps at both ends, so a wheel at the
    /// end of its travel is a no-op rather than an error a frontend has to
    /// handle on every notch.
    pub fn scroll(&self, to: ScrollTo) {
        self.inner.scroll(match to {
            ScrollTo::Lines { count } => Scroll::Lines(count),
            ScrollTo::PageUp => Scroll::PageUp,
            ScrollTo::PageDown => Scroll::PageDown,
            ScrollTo::Oldest => Scroll::Oldest,
            ScrollTo::Live => Scroll::Live,
        });
    }

    /// Tells both the engine and the far side that the window changed size.
    pub fn resize(&self, columns: u16, rows: u16) -> Result<(), TetherError> {
        self.inner.resize(ScreenSize::new(columns, rows)).map_err(Into::into)
    }

    /// `null` while the session is still running.
    pub fn ending(&self) -> Option<SessionEnding> {
        self.inner.ending().map(|ending| match ending {
            Ending::Exited(status) => SessionEnding::Exited { status },
            Ending::Closed => SessionEnding::Closed,
            Ending::Lost(cause) => SessionEnding::Lost { cause },
        })
    }

    /// Ends the session. Idempotent, because a frontend closing a window
    /// cannot easily know whether the far side got there first.
    pub fn close(&self) {
        self.inner.close_in_place();
    }
}
