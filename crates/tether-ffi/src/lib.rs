//! The UniFFI surface a Swift consumer sees.
//!
//! `tether-core` stays binding-agnostic; everything UniFFI touches lives here.
//! Nothing in this file may expose a pointer, a callback in the C sense, a
//! dispatch queue, or a backend error number (spec §13, §18).

uniffi::setup_scaffolding!();

mod input;
mod screen;
mod session;
mod tmux;
pub use tmux::*;

pub use input::{KeyModifiers, KeyPress, Resolved, TerminalInput};
pub use screen::{
    CaretShape, CellColor, CellStyle, ColorName, ScreenFrame, ScreenRow, StyledRun, UnderlineStyle,
};
pub use session::{
    Destination, HostIdentity, HostTrust, Secret, Session, SessionEnding, connect,
    connect_cancellable,
};

/// One prompt from an interactive authentication exchange.
///
/// Deliberately opaque: text the server chose, and whether a person's typing
/// should be visible. Nothing here says "password" or "OTP", because the
/// server did not (spec §10).
#[derive(Debug, Clone, uniffi::Record)]
pub struct AuthPrompt {
    pub text: String,
    pub echo: bool,
}

/// What Tether asks the application when a server wants an interactive answer.
///
/// This is the shape that made a Rust core worth its FFI seam: the call
/// travels *upward*, from the protocol into the UI, and the answer comes back
/// asynchronously — a person has to read the prompt and type.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait InteractivePrompter: Send + Sync {
    /// Returns one answer per prompt, in order. An empty vector means the
    /// person declined; the caller treats that as cancellation.
    async fn answer(&self, instruction: String, prompts: Vec<AuthPrompt>) -> Vec<String>;
}

/// A cancellation signal a consumer can raise.
///
/// UniFFI 0.32's Swift bindings poll a Rust future to completion and never
/// consult `Task.isCancelled`, so Swift's structured cancellation does not
/// reach Rust on its own — measured, not assumed: a cancelled 3s call returned
/// normally after 3002ms. Cancellation is therefore part of the API rather
/// than something the binding layer is trusted to provide. The Swift façade
/// ties it back to `withTaskCancellationHandler`, so a consumer still writes
/// ordinary Swift.
#[derive(uniffi::Object)]
pub struct CancellationToken {
    inner: tokio_util::sync::CancellationToken,
}

#[uniffi::export]
impl CancellationToken {
    #[uniffi::constructor]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self { inner: tokio_util::sync::CancellationToken::new() })
    }

    pub fn cancel(&self) {
        self.inner.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.is_cancelled()
    }
}

/// Everything that can go wrong, in our words.
///
/// A backend's error number is diagnostic context inside `cause`, never the
/// shape a consumer matches on — switching SSH libraries must not be a
/// breaking change for an application (spec §18).
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum TetherError {
    #[error("the person declined to answer")]
    Cancelled,
    #[error("timed out after {millis}ms")]
    TimedOut { millis: u64 },

    #[error("could not reach {endpoint}: {cause}")]
    Unreachable { endpoint: String, cause: String },

    /// The application's own trust decision, reported back to it. Not a
    /// failure of the connection: nothing was sent.
    #[error("the host key for {endpoint} was not trusted")]
    HostRejected { endpoint: String },

    #[error("authentication failed; the server still wants: {}", .remaining.join(", "))]
    AuthenticationFailed { remaining: Vec<String> },

    /// The credential was *accepted* and the server wants another factor, but
    /// none was left to offer. Distinct from a rejection, because telling
    /// someone their password was wrong when it was right is its own failure.
    #[error("another factor is needed: {}", .remaining.join(", "))]
    MoreFactorsNeeded { remaining: Vec<String> },

    #[error("no credentials were offered")]
    NothingToOffer,

    #[error("the server refused to open a shell: {cause}")]
    ShellRefused { cause: String },

    #[error("the connection was lost: {cause}")]
    Disconnected { cause: String },

    #[error("the session has ended")]
    SessionEnded,

    #[error("protocol failure: {cause}")]
    Protocol { cause: String },
}

impl From<tether_core::ssh::SshError> for TetherError {
    fn from(error: tether_core::ssh::SshError) -> Self {
        use tether_core::ssh::SshError;
        match error {
            SshError::Unreachable { endpoint, cause } => Self::Unreachable { endpoint, cause },
            SshError::HostRejected { endpoint } => Self::HostRejected { endpoint },
            SshError::Declined => Self::Cancelled,
            SshError::ShellRefused { cause } => Self::ShellRefused { cause },
            SshError::Disconnected { cause } => Self::Disconnected { cause },
            SshError::Protocol { cause } => Self::Protocol { cause },
            // Everything else is an authentication refusal with nothing more
            // specific to say. Matching exhaustively rather than with a
            // catch-all would break on an upstream variant we cannot see.
            other => Self::AuthenticationFailed { remaining: vec![other.to_string()] },
        }
    }
}

impl From<tether_core::DialError> for TetherError {
    fn from(error: tether_core::DialError) -> Self {
        use tether_core::DialError;
        match error {
            DialError::Refused { remaining } => Self::AuthenticationFailed { remaining },
            DialError::MoreFactorsNeeded { remaining } => Self::MoreFactorsNeeded { remaining },
            DialError::NothingToOffer => Self::NothingToOffer,
            DialError::Ssh(error) => error.into(),
        }
    }
}

impl From<tether_core::SessionError> for TetherError {
    fn from(error: tether_core::SessionError) -> Self {
        use tether_core::SessionError;
        match error {
            SessionError::Ended => Self::SessionEnded,
            SessionError::Failed(cause) => Self::Protocol { cause },
        }
    }
}

/// What this build is composed of. Synchronous, for about screens.
#[uniffi::export]
pub fn composition() -> Vec<String> {
    tether_core::composition()
}

/// Exercises the async seam with a cancellable wait.
///
/// `async_runtime = "tokio"` is not decoration: UniFFI drives the future from
/// the *foreign* executor, which is why Swift's cooperative pool and a Rust
/// event loop never fight — but a future that uses Tokio primitives still
/// needs a Tokio reactor in scope. Without this, `tokio::time::sleep` panics
/// with "there is no reactor running". The runtime's ownership is explicit
/// here rather than ambient (spec §13).
///
/// Phase 0 uses it to prove that a Swift `Task` cancellation reaches a Rust
/// future, and that a timeout raised in Rust surfaces as a typed Swift error.
#[uniffi::export(async_runtime = "tokio")]
pub async fn probe_delay(
    millis: u64,
    budget_millis: u64,
    token: Option<std::sync::Arc<CancellationToken>>,
) -> Result<String, TetherError> {
    let work = tokio::time::sleep(std::time::Duration::from_millis(millis));
    let cancelled = async {
        match &token {
            Some(t) => t.inner.cancelled().await,
            // No token means no way to cancel; wait forever on this branch.
            None => std::future::pending::<()>().await,
        }
    };

    tokio::select! {
        result = tokio::time::timeout(std::time::Duration::from_millis(budget_millis), work) => {
            match result {
                Ok(()) => Ok(format!("waited {millis}ms")),
                Err(_) => Err(TetherError::TimedOut { millis: budget_millis }),
            }
        }
        () = cancelled => Err(TetherError::Cancelled),
    }
}

/// Drives an interactive exchange through the foreign prompter.
///
/// Stands in for keyboard-interactive until Phase 1: it asks twice, which is
/// the multi-round case, and treats an empty answer as the person declining.
#[uniffi::export(async_runtime = "tokio")]
pub async fn run_interactive_exchange(
    prompter: std::sync::Arc<dyn InteractivePrompter>,
) -> Result<Vec<String>, TetherError> {
    let mut collected = Vec::new();

    for round in 1..=2u8 {
        let prompts =
            vec![AuthPrompt { text: format!("Round {round}: answer please"), echo: round == 1 }];
        let answers = prompter.answer(format!("round {round}"), prompts).await;

        if answers.is_empty() {
            return Err(TetherError::Cancelled);
        }
        collected.extend(answers);
    }

    Ok(collected)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A signalled token aborts the work rather than letting it run out.
    #[tokio::test]
    async fn cancel_interrupts_in_flight_work() {
        let token = CancellationToken::new();
        let watcher = token.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            watcher.cancel();
        });

        let start = std::time::Instant::now();
        let result = probe_delay(5_000, 10_000, Some(token)).await;

        assert!(matches!(result, Err(TetherError::Cancelled)));
        assert!(start.elapsed().as_millis() < 1_000, "work was not interrupted");
    }

    /// Cancellation and expiry are different outcomes, not one blurred error.
    #[tokio::test]
    async fn timeout_is_not_cancellation() {
        let result = probe_delay(5_000, 20, Some(CancellationToken::new())).await;
        assert!(matches!(result, Err(TetherError::TimedOut { millis: 20 })));
    }

    /// Without a token the call still completes; cancellation is opt-in.
    #[tokio::test]
    async fn absent_token_does_not_block_completion() {
        assert_eq!(probe_delay(10, 1_000, None).await.unwrap(), "waited 10ms");
    }

    /// A token signalled before the call is observed immediately.
    #[tokio::test]
    async fn pre_cancelled_token_returns_at_once() {
        let token = CancellationToken::new();
        token.cancel();
        assert!(token.is_cancelled());
        assert!(matches!(
            probe_delay(5_000, 10_000, Some(token)).await,
            Err(TetherError::Cancelled)
        ));
    }
}
