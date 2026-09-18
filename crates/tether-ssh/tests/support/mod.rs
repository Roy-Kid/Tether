//! An SSH server that behaves the way the servers we actually care about do.
//!
//! It runs in-process over an in-memory pipe, so these tests need no network,
//! no privileges and no container. What it is *not* is OpenSSH: both sides
//! here speak russh, so this proves our client against a controlled peer, not
//! against the wider world. Interop with OpenSSH is a separate, opt-in test —
//! claiming otherwise from this file would be claiming more than it shows.

use std::sync::{Arc, Mutex};

use russh::server::{Auth, Handler, Msg, Response, Session};
use russh::{Channel, ChannelId, MethodKind, MethodSet, Pty};

pub const USER: &str = "scientist";
pub const PASSWORD: &str = "correct horse";
pub const ONE_TIME_CODE: &str = "424242";
pub const BANNER: &str = "tether-test-shell\r\n";

/// A fixed host key, so the fingerprint a verifier is shown is the same on
/// every run and a test can assert the exact string. Generated for this file,
/// used nowhere else, and guarding nothing.
pub const HOST_KEY: &str = r#"-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDVbYhdAYcgHZNVFlPfqwt2JwzE6dtRY+6XW0V/qrF8BAAAAJg/OgMjPzoD
IwAAAAtzc2gtZWQyNTUxOQAAACDVbYhdAYcgHZNVFlPfqwt2JwzE6dtRY+6XW0V/qrF8BA
AAAED9V2ggp9ZFhxvsstlCfmZ9KZBtvqSX9dqRHMPN/msNtNVtiF0BhyAdk1UWU9+rC3Yn
DMTp21Fj7pdbRX+qsXwEAAAAEHRldGhlci10ZXN0LWhvc3QBAgMEBQ==
-----END OPENSSH PRIVATE KEY-----
"#;

/// What `ssh-keygen -lf` prints for [`HOST_KEY`] — the form a person compares
/// against what their administrator published.
pub const HOST_FINGERPRINT: &str = "SHA256:jS2Uw2Pj+LpBg7nf95M4x4P9lwUcS62ylTbhzR4IJKs";

/// A client key this fake host will accept. Test-only, like the host key.
pub const CLIENT_KEY: &str = r#"-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDM97920k7LDPdzaq3YmzlHLLzlDi68bS8YHTyGQmrtGwAAAJiBwAJJgcAC
SQAAAAtzc2gtZWQyNTUxOQAAACDM97920k7LDPdzaq3YmzlHLLzlDi68bS8YHTyGQmrtGw
AAAECrfy82Q4QBC4qBntLKwRCUlSAnieiQ90X956NBFGoKRsz3v3bSTssM93NqrdibOUcs
vOUOLrxtLxgdPIZCau0bAAAAEnRldGhlci10ZXN0LWNsaWVudAECAw==
-----END OPENSSH PRIVATE KEY-----
"#;

pub const CLIENT_PUBLIC_KEY: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMz3v3bSTssM93NqrdibOUcsvOUOLrxtLxgdPIZCau0b tether-test-client";

/// What a fake host will and will not accept.
///
/// A struct rather than a pile of booleans on the handler because these
/// combine: "a key, then a code" is a different server from "a code", and both
/// are real.
#[derive(Debug, Clone, Default)]
pub struct Policy {
    /// Demand a second interactive round after the password is accepted.
    pub two_factor: bool,
    /// An `authorized_keys` line to accept, if any.
    pub accepts_key: Option<&'static str>,
    /// Accept the key only as a *first* factor, then still demand
    /// keyboard-interactive — how a cluster pairs a key with a one-time code.
    pub key_is_only_the_first_factor: bool,
}

/// What the server observed, for tests to assert against.
#[derive(Debug, Default)]
pub struct Observed {
    pub pty_term: Option<String>,
    pub pty_size: Option<(u32, u32)>,
    pub resizes: Vec<(u32, u32)>,
    pub password_attempts: u32,
    pub public_key_attempts: u32,
    pub received: Vec<u8>,
}

#[derive(Clone)]
pub struct FakeHost {
    pub observed: Arc<Mutex<Observed>>,
    /// Which round of the interactive exchange we are in.
    round: u32,
    policy: Policy,
}

impl FakeHost {
    pub fn new(policy: Policy) -> Self {
        Self { observed: Arc::new(Mutex::new(Observed::default())), round: 0, policy }
    }
}

fn only_interactive() -> Option<MethodSet> {
    Some(MethodSet::from(&[MethodKind::KeyboardInteractive][..]))
}

fn challenge(
    name: &'static str,
    instructions: &'static str,
    prompt: &'static str,
    echo: bool,
) -> Auth {
    Auth::Partial {
        name: name.into(),
        instructions: instructions.into(),
        prompts: vec![(prompt.into(), echo)].into(),
    }
}

impl Handler for FakeHost {
    type Error = russh::Error;

    /// Refuses passwords outright and points the client at
    /// keyboard-interactive. This is the shape that made a
    /// password-only client useless against real institutional hosts.
    async fn auth_password(&mut self, _: &str, _: &str) -> Result<Auth, Self::Error> {
        self.observed.lock().unwrap().password_attempts += 1;
        Ok(Auth::Reject { proceed_with_methods: only_interactive(), partial_success: false })
    }

    async fn auth_publickey(
        &mut self,
        _: &str,
        offered: &russh::keys::ssh_key::PublicKey,
    ) -> Result<Auth, Self::Error> {
        self.observed.lock().unwrap().public_key_attempts += 1;

        let accepted = self.policy.accepts_key.is_some_and(|authorized| {
            russh::keys::ssh_key::PublicKey::from_openssh(authorized)
                .is_ok_and(|known| known.key_data() == offered.key_data())
        });

        if !accepted {
            return Ok(Auth::Reject {
                proceed_with_methods: only_interactive(),
                partial_success: false,
            });
        }

        if self.policy.key_is_only_the_first_factor {
            // Accepted, but not enough: the client must now pass a second
            // factor. This is `partial_success` on the wire.
            return Ok(Auth::Reject {
                proceed_with_methods: only_interactive(),
                partial_success: true,
            });
        }

        Ok(Auth::Accept)
    }

    async fn auth_keyboard_interactive(
        &mut self,
        user: &str,
        _: &str,
        response: Option<Response<'_>>,
    ) -> Result<Auth, Self::Error> {
        if user != USER {
            return Ok(Auth::Reject { proceed_with_methods: None, partial_success: false });
        }

        let is_new_exchange = response.is_none();
        let answers: Vec<String> = response
            .map(|r| r.map(|b| String::from_utf8_lossy(&b).into_owned()).collect())
            .unwrap_or_default();

        // A fresh exchange starts a fresh conversation. A server that kept
        // counting across attempts would make a mistyped password
        // unrecoverable, which is not how real ones behave.
        if is_new_exchange {
            self.round = 0;
        }
        self.round += 1;
        match self.round {
            // The server speaks first, in its own institutional wording, and
            // the client must not have assumed what it would say.
            1 => Ok(challenge(
                "Cluster login",
                "Authenticate with your account password.",
                "Password: ",
                false,
            )),
            2 if answers.first().map(String::as_str) == Some(PASSWORD) => {
                if self.policy.two_factor {
                    // A prompt that *does* echo, so a client that hard-codes
                    // "hide what is typed" is caught here.
                    Ok(challenge(
                        "Second factor",
                        "Enter the code from your authenticator.",
                        "One-time code: ",
                        true,
                    ))
                } else {
                    Ok(Auth::Accept)
                }
            }
            3 if answers.first().map(String::as_str) == Some(ONE_TIME_CODE) => Ok(Auth::Accept),
            _ => Ok(Auth::Reject {
                proceed_with_methods: only_interactive(),
                partial_success: false,
            }),
        }
    }

    async fn channel_open_session(
        &mut self,
        _: Channel<Msg>,
        open: russh::server::ChannelOpenHandle,
        _: &mut Session,
    ) -> Result<(), Self::Error> {
        // Dropping the handle rejects the channel, so accepting is not
        // optional bookkeeping.
        open.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        term: &str,
        columns: u32,
        rows: u32,
        _: u32,
        _: u32,
        _: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        {
            let mut observed = self.observed.lock().unwrap();
            observed.pty_term = Some(term.to_string());
            observed.pty_size = Some((columns, rows));
        }
        session.channel_success(channel)?;
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        session.data(channel, bytes::Bytes::from_static(BANNER.as_bytes()))?;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        command: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        session.data(channel, bytes::Bytes::copy_from_slice(command))?;
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.observed.lock().unwrap().received.extend_from_slice(data);
        // Echo, the way a line-disciplined shell would.
        session.data(channel, bytes::Bytes::copy_from_slice(data))?;
        Ok(())
    }

    /// Reports the new size back down the channel, so a resize is something a
    /// test can *observe* rather than merely something that did not error.
    async fn window_change_request(
        &mut self,
        channel: ChannelId,
        columns: u32,
        rows: u32,
        _: u32,
        _: u32,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.observed.lock().unwrap().resizes.push((columns, rows));
        session.data(channel, bytes::Bytes::from(format!("resized {columns}x{rows}\r\n")))?;
        Ok(())
    }
}

/// Starts the fake host on one end of an in-memory pipe and hands back the
/// other end, plus what the server sees.
pub fn start(policy: Policy) -> (tokio::io::DuplexStream, Arc<Mutex<Observed>>) {
    let host = FakeHost::new(policy);
    let observed = Arc::clone(&host.observed);
    let (client_side, server_side) = tokio::io::duplex(64 * 1024);

    let config = Arc::new(russh::server::Config {
        inactivity_timeout: None,
        auth_rejection_time: std::time::Duration::ZERO,
        keys: vec![russh::keys::decode_secret_key(HOST_KEY, None).expect("test host key")],
        ..Default::default()
    });

    tokio::spawn(async move {
        if let Ok(session) = russh::server::run_stream(config, server_side, host).await {
            let _ = session.await;
        }
    });

    (client_side, observed)
}

/// Client-side transport settings for tests: no keepalives, no timeouts, so a
/// slow machine cannot turn a correctness test into a flaky one.
pub fn client_config() -> Arc<tether_ssh::Config> {
    Arc::new(tether_ssh::Config {
        inactivity_timeout: None,
        keepalive_interval: None,
        ..Default::default()
    })
}

/// Records which host keys it was shown, and accepts them.
pub struct TrustAndRecord {
    pub seen: Arc<Mutex<Vec<tether_ssh::HostKey>>>,
}

impl TrustAndRecord {
    pub fn new() -> Self {
        Self { seen: Arc::new(Mutex::new(Vec::new())) }
    }
}

#[async_trait::async_trait]
impl tether_ssh::HostVerifier for TrustAndRecord {
    async fn verify(
        &self,
        _: &tether_ssh::Endpoint,
        key: &tether_ssh::HostKey,
    ) -> tether_ssh::Verdict {
        self.seen.lock().unwrap().push(key.clone());
        tether_ssh::Verdict::Trusted
    }
}

/// Answers a fixed script, and records what it was asked.
pub struct ScriptedPrompter {
    answers: Mutex<std::collections::VecDeque<Vec<String>>>,
    pub seen: Arc<Mutex<Vec<tether_ssh::Challenge>>>,
}

impl ScriptedPrompter {
    pub fn new(answers: impl IntoIterator<Item = Vec<String>>) -> Self {
        Self {
            answers: Mutex::new(answers.into_iter().collect()),
            seen: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

#[async_trait::async_trait]
impl tether_ssh::Prompter for ScriptedPrompter {
    async fn answer(&self, challenge: &tether_ssh::Challenge) -> Option<Vec<String>> {
        self.seen.lock().unwrap().push(challenge.clone());
        self.answers.lock().unwrap().pop_front()
    }
}
