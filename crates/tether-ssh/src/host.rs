//! Where to connect, and whether to trust what answers.
//!
//! Host trust is a *policy*, and this crate holds only the mechanism for
//! asking about it. Where known hosts are stored, and how a person is asked
//! about an unknown one, belong above (law: dependencies follow policy).

use crate::error::SshError;

/// A host and port to reach.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
}

impl Endpoint {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self { host: host.into(), port }
    }
}

impl std::fmt::Display for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.host, self.port)
    }
}

/// The key a host presented, described so a verifier can decide about it
/// without linking against an SSH library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKey {
    /// e.g. `ssh-ed25519`.
    pub algorithm: String,
    /// `SHA256:…`, the form a person sees in every other SSH client. Matching
    /// that wording is not cosmetic: it is how someone checks a key against
    /// what their administrator published.
    pub fingerprint: String,
    /// The wire encoding, for a verifier that stores keys rather than
    /// fingerprints.
    pub encoded: Vec<u8>,
}

/// The answer to "should we talk to this host?".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Trusted,
    Rejected,
}

/// Decides whether a host key is acceptable.
///
/// Called during the handshake, before any credential is sent — which is the
/// point: a credential handed to an unverified host is already disclosed.
#[async_trait::async_trait]
pub trait HostVerifier: Send + Sync {
    async fn verify(&self, endpoint: &Endpoint, key: &HostKey) -> Verdict;
}

/// Trusts nothing. The default a caller must consciously replace.
pub struct RejectAll;

#[async_trait::async_trait]
impl HostVerifier for RejectAll {
    async fn verify(&self, _: &Endpoint, _: &HostKey) -> Verdict {
        Verdict::Rejected
    }
}

pub(crate) fn describe(
    key: &russh::keys::PublicKeyOrCertificate,
) -> Result<HostKey, SshError> {
    use russh::keys::ssh_key::{HashAlg, public::PublicKey};

    let public = match key {
        russh::keys::PublicKeyOrCertificate::PublicKey { key, .. } => key.clone(),
        // A certificate's own signature chain is the verifier's business, not
        // ours; what we report is the key inside it, described the same way.
        russh::keys::PublicKeyOrCertificate::Certificate(cert) => {
            PublicKey::new(cert.public_key().clone(), "")
        }
    };

    Ok(HostKey {
        algorithm: public.algorithm().as_str().to_string(),
        fingerprint: public.fingerprint(HashAlg::Sha256).to_string(),
        // The `authorized_keys` one-line form: what a person pastes, and what
        // a `known_hosts` file already holds.
        encoded: public
            .to_openssh()
            .map_err(SshError::protocol)?
            .into_bytes(),
    })
}
