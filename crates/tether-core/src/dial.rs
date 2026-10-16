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

use tether_ssh::{
    Connection, Endpoint, HostVerifier, KeyError, KeyUnlocker, PrivateKey, Prompter, SshError,
    Step, WindowSize,
};
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
    ///
    /// A key protected by a passphrase is unlocked with `passphrase` when one
    /// is given, and otherwise through `unlock` — asked only once the server
    /// has said it would take the key. With neither, it is left out.
    PrivateKey {
        pem: String,
        passphrase: Option<String>,
        unlock: Option<Arc<dyn KeyUnlocker>>,
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

/// A private key left out of a login, and why.
///
/// Named by where it sat in the credentials the caller gave, counting from
/// zero: the caller built that list, so it knows which file or keychain item
/// that was — a name this crate never learns (spec §4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkippedKey {
    pub position: usize,
    /// `SHA256:…`, when the key could be read far enough to have one.
    pub fingerprint: Option<String>,
    pub problem: KeyError,
}

/// What went wrong between a hostname and a shell.
#[derive(Debug, thiserror::Error)]
pub enum DialError {
    /// Every credential was offered and the server took none of them.
    ///
    /// Carries what the server said it would still accept, so a consumer can
    /// tell a person "this host wants a key" rather than "login failed" —
    /// and the keys that were never offered, because "your key was not used,
    /// and here is why" is often the whole story.
    #[error("authentication failed; the server still wants: {}", .remaining.join(", "))]
    Refused { remaining: Vec<String>, skipped: Vec<SkippedKey> },

    /// No credential could be used: every one given was a key that could not
    /// be read, or a key's passphrase was wrong every time it was asked for.
    /// The server was not refused anything; this side had nothing to offer.
    #[error("no credential could be used")]
    Unusable { skipped: Vec<SkippedKey> },

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
    history: Option<crate::history::HistoryArchive>,
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
            history: None,
            jumps: Vec::new(),
        }
    }

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

    pub fn history(mut self, history: Option<crate::history::HistoryArchive>) -> Self {
        self.history = history;
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
        let history = self.history.clone();
        let term = self.term.clone();
        let connection = self.authenticate(credentials).await?;
        let shell =
            connection.shell(&term, WindowSize::new(size.columns as u32, size.rows as u32)).await?;
        Ok(TerminalSession::start_with(
            shell,
            size,
            options,
            crate::Connection::Remote(connection),
            None,
            None,
            history,
        ))
    }

    /// Authenticate once, then open independent channels on this connection.
    ///
    /// Keys are read before anything is dialled. One that cannot be used is
    /// left out — logged, never printed — and reported with the outcome if
    /// the login fails; it does not take the credentials after it down too.
    pub async fn authenticate(
        self,
        credentials: Vec<Credential>,
    ) -> Result<Arc<tether_ssh::Session>, DialError> {
        if credentials.is_empty() {
            return Err(DialError::NothingToOffer);
        }
        let (offers, skipped) = prepare(credentials);
        if offers.is_empty() {
            return Err(DialError::Unusable { skipped });
        }
        let mut via = None;
        for jump in self.jumps {
            let endpoint = jump.endpoint;
            let connection = match via.take() {
                Some(previous) => {
                    Connection::connect_through(
                        previous,
                        endpoint,
                        Arc::clone(&self.verifier),
                        Arc::clone(&self.config),
                    )
                    .await?
                }
                None => {
                    Connection::connect(
                        endpoint,
                        Arc::clone(&self.verifier),
                        Arc::clone(&self.config),
                    )
                    .await?
                }
            };
            via = Some(login(connection, &jump.user, jump.credentials).await?);
        }
        let connection = match via {
            Some(previous) => {
                Connection::connect_through(previous, self.endpoint, self.verifier, self.config)
                    .await?
            }
            None => Connection::connect(self.endpoint, self.verifier, self.config).await?,
        };
        Ok(Arc::new(login_prepared(connection, &self.user, offers, skipped).await?))
    }
}

async fn login(
    connection: Connection,
    user: &str,
    credentials: Vec<Credential>,
) -> Result<tether_ssh::Session, DialError> {
    if credentials.is_empty() {
        return Err(DialError::NothingToOffer);
    }
    let (offers, skipped) = prepare(credentials);
    if offers.is_empty() {
        return Err(DialError::Unusable { skipped });
    }
    login_prepared(connection, user, offers, skipped).await
}

async fn login_prepared(
    mut connection: Connection,
    user: &str,
    offers: Vec<Offer>,
    mut skipped: Vec<SkippedKey>,
) -> Result<tether_ssh::Session, DialError> {
    let mut refused = Vec::new();
    let mut offered = offers.into_iter().peekable();

    let session = loop {
        let Some(offer) = offered.next() else {
            // Out of credentials. Which error depends on how the last
            // attempt went, and that distinction is the difference
            // between "your password is wrong" and "now your code".
            return Err(DialError::Refused { remaining: refused, skipped });
        };

        // A key with no readable public half is unlocked before its turn,
        // while nothing about it has reached the server: a no, or three
        // wrong passphrases, leave it out and keep the connection for the
        // credentials after it — as ssh moves on to its next key.
        let offer = match offer {
            Offer::Key { position, key, unlock: Some(unlock) } if key.unlocks_first() => {
                match key.opened(unlock.as_ref()).await {
                    Ok(open) => Offer::Key { position, key: Box::new(open), unlock: None },
                    Err(problem) => {
                        tracing::warn!(position, %problem, "a private key was left out");
                        let fingerprint = key.description().fingerprint.clone();
                        skipped.push(SkippedKey { position, fingerprint, problem });
                        continue;
                    }
                }
            }
            other => other,
        };

        let step = match attempt(connection, user, &offer).await {
            Ok(step) => step,
            // A key the server accepted and that then could not be
            // unlocked ends the login — the server is waiting for its
            // signature, so the connection went with it — and is named
            // like any other.
            Err(SshError::Key(problem)) => {
                if let Offer::Key { position, key, .. } = &offer {
                    skipped.push(SkippedKey {
                        position: *position,
                        fingerprint: key.description().fingerprint.clone(),
                        problem,
                    });
                }
                return Err(DialError::Unusable { skipped });
            }
            Err(error) => return Err(error.into()),
        };

        match step {
            Step::Authenticated(session) => break session,
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
    };

    Ok(session)
}

/// A credential that survived being read.
enum Offer {
    Password(String),
    Key { position: usize, key: Box<PrivateKey>, unlock: Option<Arc<dyn KeyUnlocker>> },
    Interactive(Arc<dyn Prompter>),
}

/// Reads every key before a connection exists, and sets aside the ones that
/// cannot be used — including a locked one with nothing to ask for its
/// passphrase, which would otherwise fail only after the server accepted it.
fn prepare(credentials: Vec<Credential>) -> (Vec<Offer>, Vec<SkippedKey>) {
    let mut offers = Vec::new();
    let mut skipped = Vec::new();
    for (position, credential) in credentials.into_iter().enumerate() {
        match credential {
            Credential::Password(password) => offers.push(Offer::Password(password)),
            Credential::Interactive(prompter) => offers.push(Offer::Interactive(prompter)),
            Credential::PrivateKey { pem, passphrase, unlock } => {
                let read = PrivateKey::parse(&pem, passphrase.as_deref()).and_then(|key| {
                    if key.needs_passphrase() && unlock.is_none() {
                        Err(KeyError::Locked)
                    } else {
                        Ok(key)
                    }
                });
                match read {
                    Ok(key) => offers.push(Offer::Key { position, key: Box::new(key), unlock }),
                    Err(problem) => {
                        tracing::warn!(position, %problem, "a private key was left out");
                        let fingerprint = PrivateKey::parse(&pem, None)
                            .ok()
                            .and_then(|key| key.description().fingerprint.clone());
                        skipped.push(SkippedKey { position, fingerprint, problem });
                    }
                }
            }
        }
    }
    (offers, skipped)
}

impl std::fmt::Debug for Dial {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Dial")
            .field("endpoint", &self.endpoint)
            .field("user", &self.user)
            .field("term", &self.term)
            .field("size", &self.size)
            .finish_non_exhaustive()
    }
}

async fn attempt(connection: Connection, user: &str, offer: &Offer) -> Result<Step, SshError> {
    match offer {
        Offer::Password(password) => connection.password(user, password).await,
        Offer::Key { key, unlock, .. } => {
            connection.private_key(user, key, unlock.as_deref()).await
        }
        Offer::Interactive(prompter) => {
            // A wrong code ends this round and leaves keyboard-interactive
            // available. Ask again on the same connection instead of
            // reporting the login as failed.
            let mut connection = connection;
            for _ in 0..4 {
                match connection.interactive(user, prompter.as_ref()).await? {
                    Step::Rejected { remaining, retry }
                        if remaining.iter().any(|method| method.0 == "keyboard-interactive") =>
                    {
                        connection = retry;
                    }
                    other => return Ok(other),
                }
            }
            connection.interactive(user, prompter.as_ref()).await
        }
    }
}

fn names(methods: &[tether_ssh::Method]) -> Vec<String> {
    methods.iter().map(|method| method.0.clone()).collect()
}
