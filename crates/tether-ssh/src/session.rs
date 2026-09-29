//! Connecting, proving who you are, and holding a session open.
//!
//! The ordering that SSH requires — verify the host, then authenticate, then
//! open a channel — is carried by the types. There is no `Session` to open a
//! shell on until authentication has actually succeeded, so the sequence is
//! not a convention a caller can forget (law: explicit flow).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::auth::{Challenge, Method, Prompt, Prompter};
use crate::error::SshError;
use crate::host::{Endpoint, HostVerifier, Verdict};
use crate::key::{KeyError, KeyUnlocker, PrivateKey, Unlocking};
use crate::shell::{Shell, WindowSize};

/// Bridges russh's callbacks onto our own policy interfaces.
struct ClientHandler {
    endpoint: Endpoint,
    verifier: Arc<dyn HostVerifier>,
    /// Set when the verifier refused, so the handshake error that follows can
    /// be reported as what it was rather than as a generic protocol failure.
    host_refused: Arc<AtomicBool>,
}

impl russh::client::Handler for ClientHandler {
    type Error = SshError;

    async fn check_server_key(
        &mut self,
        key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let described = crate::host::describe(key)?;
        match self.verifier.verify(&self.endpoint, &described).await {
            Verdict::Trusted => Ok(true),
            Verdict::Rejected => {
                self.host_refused.store(true, Ordering::SeqCst);
                Ok(false)
            }
        }
    }
}

/// A connection whose host has been verified but which has not authenticated.
///
/// It cannot open a channel; that is the point.
pub struct Connection {
    handle: russh::client::Handle<ClientHandler>,
    endpoint: Endpoint,
}

/// What an authentication attempt produced.
#[derive(Debug)]
pub enum Step {
    /// Authenticated. The connection has become a session.
    Authenticated(Session),
    /// The factor was accepted but the server wants another one — ordinary
    /// multi-factor, not a failure. Common wherever a cluster pairs a key
    /// with a one-time code.
    AnotherFactor { remaining: Vec<Method>, next: Connection },
    /// The attempt was refused. The connection survives, so a caller can let
    /// a person correct a typo without dialling again.
    Rejected { remaining: Vec<Method>, retry: Connection },
}

impl Connection {
    /// Reaches `endpoint` and verifies its host key.
    ///
    /// The verifier runs during the handshake, before any credential exists
    /// in this process's memory, let alone on the wire.
    pub async fn connect(
        endpoint: Endpoint,
        verifier: Arc<dyn HostVerifier>,
        config: Arc<russh::client::Config>,
    ) -> Result<Self, SshError> {
        let host_refused = Arc::new(AtomicBool::new(false));
        let handler = ClientHandler {
            endpoint: endpoint.clone(),
            verifier,
            host_refused: Arc::clone(&host_refused),
        };

        let handle =
            russh::client::connect(config, (endpoint.host.clone(), endpoint.port), handler)
                .await
                .map_err(|error| classify_connect(error, &endpoint, &host_refused))?;

        Ok(Self { handle, endpoint })
    }

    /// Connects over an existing stream rather than dialling.
    ///
    /// Exists because a transport is not always a TCP socket — a test harness,
    /// a jump host's forwarded channel — and because dialling is the one part
    /// of a session that cannot be exercised in memory.
    pub async fn connect_over<S>(
        endpoint: Endpoint,
        stream: S,
        verifier: Arc<dyn HostVerifier>,
        config: Arc<russh::client::Config>,
    ) -> Result<Self, SshError>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let host_refused = Arc::new(AtomicBool::new(false));
        let handler = ClientHandler {
            endpoint: endpoint.clone(),
            verifier,
            host_refused: Arc::clone(&host_refused),
        };

        let handle = russh::client::connect_stream(config, stream, handler)
            .await
            .map_err(|error| classify_connect(error, &endpoint, &host_refused))?;

        Ok(Self { handle, endpoint })
    }

    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    /// Asks the server what it will accept, without offering anything.
    ///
    /// This is how a caller can tell someone "this host wants a key and a
    /// one-time code" before asking them for either.
    pub async fn offered_methods(mut self, user: &str) -> Result<Step, SshError> {
        let result = self.handle.authenticate_none(user).await?;
        Ok(self.step_from(result))
    }

    pub async fn password(mut self, user: &str, password: &str) -> Result<Step, SshError> {
        let result = self.handle.authenticate_password(user, password).await?;
        Ok(self.step_from(result))
    }

    /// Authenticates with a private key.
    ///
    /// The key is a [`PrivateKey`] the caller already read, not text: reading
    /// is where a key turns out to be unusable, and finding that out here
    /// would cost the connection this call consumes — and every credential
    /// that was going to be tried on it after this one.
    ///
    /// A locked key is unlocked through `unlocker`, and only when it has to
    /// be. OpenSSH's format keeps the public half readable, so the server is
    /// asked about it first and the person is asked only once the server has
    /// said yes. The other formats have nothing to ask the server with; a
    /// caller that wants a no to cost only that key opens them first with
    /// [`PrivateKey::opened`], and one that does not has them unlocked here.
    ///
    /// A person declining is [`SshError::Declined`]; every passphrase wrong
    /// is [`SshError::Key`]. Either way the connection is gone: once the
    /// server has been told a signature is coming, nothing else can be said
    /// on it.
    pub async fn private_key(
        mut self,
        user: &str,
        key: &PrivateKey,
        unlocker: Option<&dyn KeyUnlocker>,
    ) -> Result<Step, SshError> {
        if let Some(ready) = key.ready_key() {
            return self.sign_in(user, ready.clone()).await;
        }
        let Some(unlocker) = unlocker else {
            return Err(SshError::Key(KeyError::Locked));
        };

        let Some(public) = key.sealed_public_key() else {
            let ready = key.unlock(unlocker).await.map_err(unlocking_error)?;
            return self.sign_in(user, ready).await;
        };

        let hash = if matches!(public.algorithm(), russh::keys::Algorithm::Rsa { .. }) {
            self.handle.best_supported_rsa_hash().await?.flatten()
        } else {
            None
        };
        let mut signer = Unlock { key, unlocker };
        match self.handle.authenticate_publickey_with(user, public.clone(), hash, &mut signer).await
        {
            Ok(result) => Ok(self.step_from(result)),
            Err(UnlockFailure::Unlocking(unlocking)) => Err(unlocking_error(unlocking)),
            Err(UnlockFailure::Signing(cause)) => Err(SshError::protocol(cause)),
            Err(UnlockFailure::Send) => {
                Err(SshError::Disconnected { cause: "the connection closed mid-login".to_owned() })
            }
        }
    }

    async fn sign_in(mut self, user: &str, key: russh::keys::PrivateKey) -> Result<Step, SshError> {
        let best_hash = self.handle.best_supported_rsa_hash().await?.flatten();

        let result = self
            .handle
            .authenticate_publickey(
                user,
                russh::keys::PrivateKeyWithHashAlg::new(Arc::new(key), best_hash),
            )
            .await?;
        Ok(self.step_from(result))
    }

    /// Runs a keyboard-interactive exchange to whatever length the server
    /// drives it, asking `prompter` each round.
    pub async fn interactive(
        mut self,
        user: &str,
        prompter: &dyn Prompter,
    ) -> Result<Step, SshError> {
        use russh::client::KeyboardInteractiveAuthResponse as Response;

        let mut response = self.handle.authenticate_keyboard_interactive_start(user, None).await?;

        loop {
            match response {
                Response::Success => {
                    return Ok(Step::Authenticated(Session {
                        handle: self.handle,
                        endpoint: self.endpoint,
                    }));
                }
                Response::Failure { remaining_methods, partial_success } => {
                    return Ok(self.step_from(russh::client::AuthResult::Failure {
                        remaining_methods,
                        partial_success,
                    }));
                }
                Response::InfoRequest { prompts, .. } if prompts.is_empty() => {
                    // A round with no prompts is the server talking, not
                    // asking: PAM text such as "your password expires in 3
                    // days" arrives this way, typically once a code has
                    // already been accepted. RFC 4256 still wants a reply,
                    // and the reply is an answer with no fields. Nobody is
                    // asked, because there is nothing to answer — and asking
                    // would mistake the message for a question and read the
                    // empty answer as someone declining.
                    response =
                        self.handle.authenticate_keyboard_interactive_respond(Vec::new()).await?;
                }
                Response::InfoRequest { name, instructions, prompts } => {
                    let challenge = Challenge {
                        name,
                        instruction: instructions,
                        prompts: prompts
                            .into_iter()
                            .map(|p| Prompt { text: p.prompt, echo: p.echo })
                            .collect(),
                    };

                    let Some(answers) = prompter.answer(&challenge).await else {
                        // Declining is a decision, not a rejected credential.
                        // Reporting it as "authentication failed" would tell a
                        // person their password was wrong when they never gave
                        // one.
                        return Err(SshError::Declined);
                    };

                    response =
                        self.handle.authenticate_keyboard_interactive_respond(answers).await?;
                }
            }
        }
    }

    fn step_from(self, result: russh::client::AuthResult) -> Step {
        match result {
            russh::client::AuthResult::Success => {
                Step::Authenticated(Session { handle: self.handle, endpoint: self.endpoint })
            }
            russh::client::AuthResult::Failure { remaining_methods, partial_success } => {
                let remaining = remaining_methods.iter().map(|m| Method(String::from(m))).collect();
                if partial_success {
                    Step::AnotherFactor { remaining, next: self }
                } else {
                    Step::Rejected { remaining, retry: self }
                }
            }
        }
    }
}

/// Signs for a key that is unlocked only when the server asks for the
/// signature — which russh does only after the server accepted the key's
/// public half.
struct Unlock<'a> {
    key: &'a PrivateKey,
    unlocker: &'a dyn KeyUnlocker,
}

#[derive(Debug)]
enum UnlockFailure {
    Unlocking(Unlocking),
    Signing(String),
    Send,
}

impl From<russh::SendError> for UnlockFailure {
    fn from(_: russh::SendError) -> Self {
        Self::Send
    }
}

impl russh::Signer for Unlock<'_> {
    type Error = UnlockFailure;

    #[allow(clippy::manual_async_fn)] // the trait asks for a `Send` future by name
    fn auth_sign(
        &mut self,
        _: &russh::keys::agent::AgentIdentity,
        hash: Option<russh::keys::HashAlg>,
        to_sign: Vec<u8>,
    ) -> impl Future<Output = Result<Vec<u8>, Self::Error>> + Send {
        async move {
            let key = self.key.unlock(self.unlocker).await.map_err(UnlockFailure::Unlocking)?;
            let signature =
                crate::key::sign(&key, hash, &to_sign).map_err(UnlockFailure::Signing)?;
            // The signature follows the signed bytes as an SSH string, which
            // is what russh writes for a key it holds itself.
            let mut signed = to_sign;
            russh::keys::ssh_encoding::Encode::encode(signature.as_slice(), &mut signed)
                .map_err(|error| UnlockFailure::Signing(error.to_string()))?;
            Ok(signed)
        }
    }
}

fn unlocking_error(unlocking: Unlocking) -> SshError {
    match unlocking {
        // The same decision as walking away from an interactive prompt.
        Unlocking::Declined => SshError::Declined,
        Unlocking::Failed(error) => SshError::Key(error),
    }
}

impl std::fmt::Debug for Connection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Connection").field("endpoint", &self.endpoint).finish()
    }
}

/// An authenticated session. Channels can be opened on it, and only on it.
pub struct Session {
    handle: russh::client::Handle<ClientHandler>,
    endpoint: Endpoint,
}

impl Session {
    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    /// Opens an interactive shell with a pseudo-terminal attached.
    ///
    /// `term` is what the far side will see in `$TERM`; it decides which
    /// escape sequences programs there will emit, so it must describe what
    /// the *consumer* can actually render, not what we wish it could.
    pub async fn shell(&self, term: &str, size: WindowSize) -> Result<Shell, SshError> {
        let mut channel = self
            .handle
            .channel_open_session()
            .await
            .map_err(|error| SshError::ShellRefused { cause: error.to_string() })?;

        // Empty terminal modes leaves the server at its own defaults, which is
        // what OpenSSH sends when it has nothing to override.
        channel
            .request_pty(true, term, size.columns, size.rows, 0, 0, &[])
            .await
            .map_err(|error| SshError::ShellRefused { cause: error.to_string() })?;
        confirm(&mut channel, "the pseudo-terminal").await?;

        channel
            .request_shell(true)
            .await
            .map_err(|error| SshError::ShellRefused { cause: error.to_string() })?;
        confirm(&mut channel, "the shell").await?;

        Ok(Shell { channel, size })
    }

    /// Opens a command channel without a PTY. Output is never mixed with a shell.
    pub async fn exec(&self, command: &str) -> Result<Shell, SshError> {
        let mut channel = self.handle.channel_open_session().await?;
        channel.exec(true, command).await?;
        confirm(&mut channel, "the command").await?;
        Ok(Shell { channel, size: WindowSize::default() })
    }

    /// Opens a channel on a named subsystem — a program the *server* chose
    /// for that name, such as its `sftp-server` for `sftp`. No PTY and no
    /// command line: nothing is parsed by a shell on the far side.
    pub async fn subsystem(&self, name: &str) -> Result<Shell, SshError> {
        let mut channel = self.handle.channel_open_session().await?;
        channel.request_subsystem(true, name).await?;
        confirm(&mut channel, &format!("the {name} subsystem")).await?;
        Ok(Shell { channel, size: WindowSize::default() })
    }

    /// Ends the session, telling the server why.
    pub async fn disconnect(self) -> Result<(), SshError> {
        self.handle.disconnect(russh::Disconnect::ByApplication, "", "en").await.map_err(Into::into)
    }
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session").field("endpoint", &self.endpoint).finish()
    }
}

/// A refused host key surfaces from russh as an ordinary handshake failure.
/// The flag the handler set is what tells the two apart, and a person needs
/// them told apart: one means "check the fingerprint", the other "try again".
fn classify_connect(error: SshError, endpoint: &Endpoint, host_refused: &AtomicBool) -> SshError {
    if host_refused.load(Ordering::SeqCst) {
        return SshError::HostRejected { endpoint: endpoint.to_string() };
    }
    match error {
        SshError::Protocol { cause } => {
            SshError::Unreachable { endpoint: endpoint.to_string(), cause }
        }
        other => other,
    }
}

/// Waits for the server to accept or refuse a channel request.
///
/// russh sends these requests without waiting, so without this a caller would
/// receive a `Shell` before the far side agreed there was one — and a server
/// that refused the pty would hand back a shell with no terminal rather than
/// an error. `want_reply` is only worth setting if someone reads the reply.
async fn confirm(
    channel: &mut russh::Channel<russh::client::Msg>,
    what: &str,
) -> Result<(), SshError> {
    loop {
        match channel.wait().await {
            Some(russh::ChannelMsg::Success) => return Ok(()),
            Some(russh::ChannelMsg::Failure) => {
                return Err(SshError::ShellRefused { cause: format!("server refused {what}") });
            }
            // Window adjustments can arrive before the reply.
            Some(_) => continue,
            None => {
                return Err(SshError::ShellRefused {
                    cause: format!("the channel closed before {what} was granted"),
                });
            }
        }
    }
}
