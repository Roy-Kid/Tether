//! Getting from a hostname to a running session.
//!
//! `tether-ssh` exposes authentication as a state machine, one credential at
//! a time, because that is what the protocol is. A consumer almost never
//! wants to drive it — what a terminal application has is "this host, this
//! user, these credentials, give me a shell", and the branching in between is
//! ceremony it should not have to reimplement.
//!
//! This module is that ceremony, written once. It is the whole justification
//! for a composition crate: nothing here is new capability, all of it is
//! capability that was awkward to reach (spec §16).

use std::sync::Arc;

use tether_ssh::{Connection, Endpoint, HostVerifier, Prompter, SshError, Step, WindowSize};
use tether_terminal::{Options, ScreenSize};

use crate::session::TerminalSession;

/// Something to authenticate with.
///
/// A list of these rather than one, because multi-factor is the arrangement
/// this project exists for: a key *and* a one-time code is two credentials
/// and one login, not two logins (spec §10).
pub enum Credential {
    Password(String),
    /// PEM text, not a path and not a parsed key: a caller's key may live in
    /// a keychain item that never touches the filesystem.
    PrivateKey {
        pem: String,
        passphrase: Option<String>,
    },
    /// Answers whatever the server asks, for as many rounds as it asks.
    Interactive(Arc<dyn Prompter>),
}

impl std::fmt::Debug for Credential {
    /// Hand-written so a `Debug` line can never print key material. The
    /// variant is diagnostic; its contents are a secret (spec §18).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            Self::Password(_) => "Password",
            Self::PrivateKey { .. } => "PrivateKey",
            Self::Interactive(_) => "Interactive",
        };
        write!(f, "Credential::{name}")
    }
}

/// What went wrong between a hostname and a shell.
#[derive(Debug, thiserror::Error)]
pub enum DialError {
    /// Every credential was offered and the server took none of them.
    ///
    /// Carries what the server said it would still accept, so a consumer can
    /// tell a person "this host wants a key" rather than "login failed".
    #[error("authentication failed; the server still wants: {}", .remaining.join(", "))]
    Refused { remaining: Vec<String> },

    /// Credentials ran out while the server was still asking for factors.
    /// Different from [`Self::Refused`]: what was offered was *accepted*.
    #[error("the server accepted that factor and wants another: {}", .remaining.join(", "))]
    MoreFactorsNeeded { remaining: Vec<String> },

    /// No credential was supplied at all.
    #[error("no credentials were offered")]
    NothingToOffer,

    #[error(transparent)]
    Ssh(#[from] SshError),
}

/// How to reach a host and what to become once there.
///
/// A builder because the required parts (where, who) and the tuning (what
/// `$TERM` claims, how much scrollback) have very different lifetimes in a
/// consumer's code.
/// One authenticated hop in front of the destination.
///
/// A `ProxyJump` chain is these, first to last: each is logged into before
/// the next channel is opened. Credentials stay here, with the hop they
/// belong to, so a password typed for the destination is never offered to a
/// bastion.
pub struct Jump {
    pub endpoint: Endpoint,
    pub user: String,
    pub credentials: Vec<Credential>,
}

impl std::fmt::Debug for Jump {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Jump")
            .field("endpoint", &self.endpoint)
            .field("user", &self.user)
            .field("credentials", &self.credentials.len())
            .finish()
    }
}

pub struct Dial {
    endpoint: Endpoint,
    user: String,
    verifier: Arc<dyn HostVerifier>,
    config: Arc<tether_ssh::Config>,
    term: String,
    size: ScreenSize,
    options: Options,
    jumps: Vec<Jump>,
}

impl Dial {
    /// Starts a dial that will refuse every host key.
    ///
    /// [`tether_ssh::RejectAll`] is the default on purpose: a consumer must
    /// decide what trust means before a credential can leave this process
    /// (spec §18). There is no trust-all convenience to reach for.
    pub fn new(endpoint: Endpoint, user: impl Into<String>) -> Self {
        Self {
            endpoint,
            user: user.into(),
            verifier: Arc::new(tether_ssh::RejectAll),
            config: Arc::new(tether_ssh::Config::default()),
            // `xterm-256color` is what the far side will believe it is
            // talking to. It must describe what a consumer can actually
            // render; a frontend that cannot do 256 colours should say so.
            term: "xterm-256color".to_owned(),
            size: ScreenSize::new(80, 24),
            options: Options::default(),
            jumps: Vec::new(),
        }
    }

    /// Reach the destination through these hops, first to last.
    ///
    /// An empty list dials directly. Each hop is a separate login: its own
    /// host key, its own credentials, then a forwarded channel to the next.
    pub fn through(mut self, jumps: Vec<Jump>) -> Self {
        self.jumps = jumps;
        self
    }

    pub fn verifier(mut self, verifier: Arc<dyn HostVerifier>) -> Self {
        self.verifier = verifier;
        self
    }

    pub fn config(mut self, config: Arc<tether_ssh::Config>) -> Self {
        self.config = config;
        self
    }

    /// What the far side will see in `$TERM`.
    pub fn term(mut self, term: impl Into<String>) -> Self {
        self.term = term.into();
        self
    }

    pub fn size(mut self, size: ScreenSize) -> Self {
        self.size = size;
        self
    }

    pub fn options(mut self, options: Options) -> Self {
        self.options = options;
        self
    }

    /// Connects, authenticates, opens a shell, and starts pumping it.
    ///
    /// Credentials are offered in order until the server is satisfied. A
    /// credential the server accepts while still wanting another is not an
    /// error — the loop simply moves on to the next one, which is exactly
    /// what "a key, then a code" needs.
    pub async fn connect(self, credentials: Vec<Credential>) -> Result<TerminalSession, DialError> {
        let size = self.size;
        let options = self.options;
        let term = self.term.clone();
        let connection = self.authenticate(credentials).await?;
        let shell =
            connection.shell(&term, WindowSize::new(size.columns as u32, size.rows as u32)).await?;
        Ok(TerminalSession::start_with(shell, size, options, crate::Connection::Remote(connection)))
    }

    /// Authenticate once, then open independent channels on this connection.
    pub async fn authenticate(
        self,
        credentials: Vec<Credential>,
    ) -> Result<Arc<tether_ssh::Session>, DialError> {
        if credentials.is_empty() {
            return Err(DialError::NothingToOffer);
        }

        let mut via: Option<tether_ssh::Session> = None;
        for jump in self.jumps {
            let endpoint = jump.endpoint.clone();
            let connection = match via.take() {
                Some(previous) => {
                    Connection::connect_through(
                        previous,
                        endpoint.clone(),
                        Arc::clone(&self.verifier),
                        Arc::clone(&self.config),
                    )
                    .await?
                }
                None => {
                    Connection::connect(
                        endpoint.clone(),
                        Arc::clone(&self.verifier),
                        Arc::clone(&self.config),
                    )
                    .await?
                }
            };
            via = Some(
                login(connection, &jump.user, jump.credentials)
                    .await
                    .map_err(|error| attribute(&endpoint, error))?,
            );
        }

        let connection = match via.take() {
            Some(previous) => {
                Connection::connect_through(
                    previous,
                    self.endpoint.clone(),
                    Arc::clone(&self.verifier),
                    Arc::clone(&self.config),
                )
                .await?
            }
            None => {
                Connection::connect(
                    self.endpoint.clone(),
                    Arc::clone(&self.verifier),
                    Arc::clone(&self.config),
                )
                .await?
            }
        };

        // The destination's own failure is not attributed to a hop. A person
        // who typed the wrong password is already looking at that machine.
        let session = login(connection, &self.user, credentials).await?;
        Ok(Arc::new(session))
    }
}

impl std::fmt::Debug for Dial {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Dial")
            .field("endpoint", &self.endpoint)
            .field("user", &self.user)
            .field("jumps", &self.jumps)
            .field("term", &self.term)
            .field("size", &self.size)
            .finish_non_exhaustive()
    }
}

/// The credential loop, apart from how the connection was reached.
async fn login(
    mut connection: Connection,
    user: &str,
    credentials: Vec<Credential>,
) -> Result<tether_ssh::Session, DialError> {
    if credentials.is_empty() {
        return Err(DialError::NothingToOffer);
    }

    let mut refused = Vec::new();
    let mut offered = credentials.into_iter().peekable();

    loop {
        let Some(credential) = offered.next() else {
            return Err(DialError::Refused { remaining: refused });
        };

        match attempt(connection, user, credential).await? {
            Step::Authenticated(session) => return Ok(session),
            Step::AnotherFactor { remaining, next } => {
                let remaining = names(&remaining);
                if offered.peek().is_none() {
                    return Err(DialError::MoreFactorsNeeded { remaining });
                }
                refused = remaining;
                connection = next;
            }
            Step::Rejected { remaining, retry } => {
                refused = names(&remaining);
                connection = retry;
            }
        }
    }
}

/// A hop's failure has to name the hop. "Authentication failed" on its own
/// sends a person to the machine they meant to reach, which accepted nothing
/// because it was never contacted.
fn attribute(endpoint: &Endpoint, error: DialError) -> DialError {
    match error {
        DialError::Ssh(inner) => DialError::Ssh(inner),
        other => {
            DialError::Ssh(tether_ssh::SshError::Protocol { cause: format!("{endpoint}: {other}") })
        }
    }
}

async fn attempt(
    connection: Connection,
    user: &str,
    credential: Credential,
) -> Result<Step, SshError> {
    match credential {
        Credential::Password(password) => connection.password(user, &password).await,
        Credential::PrivateKey { pem, passphrase } => {
            connection.private_key(user, &pem, passphrase.as_deref()).await
        }
        Credential::Interactive(prompter) => connection.interactive(user, prompter.as_ref()).await,
    }
}

fn names(methods: &[tether_ssh::Method]) -> Vec<String> {
    methods.iter().map(|method| method.0.clone()).collect()
}
