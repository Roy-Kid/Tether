//! Private keys, read before a connection is spent on them.
//!
//! A key is parsed before anything is dialled. One that cannot be used — not
//! a key at all, a kind this client cannot sign with, locked with nothing to
//! ask for its passphrase — is found out here and left out, rather than
//! discovered mid-login, where the failure used to take the connection and
//! every credential after it down with it.
//!
//! A key protected by a passphrase is unlocked the way OpenSSH unlocks one:
//! the server is asked about the public half first, and the person is asked
//! for the passphrase only once the server has said it would accept that
//! key. Being asked to unlock a key the server was never going to take is
//! the prompt people learn to dismiss.

use russh::keys::ssh_key::{self, Algorithm, HashAlg};

/// How many passphrases a person gets before the login gives up on a key —
/// OpenSSH's number, so a person used to `ssh` is not surprised by ours.
pub const PASSPHRASE_ATTEMPTS: u32 = 3;

/// Why a key could not be used, in our words.
///
/// The parser's own error is diagnostic context in `cause`, never the shape a
/// consumer matches on (spec §18).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum KeyError {
    /// Not a private key in any format this client reads.
    #[error("it is not a private key that can be read: {cause}")]
    Unreadable { cause: String },
    /// A key of a kind this client cannot sign with — a security key whose
    /// private half lives in hardware, or DSA, which OpenSSH itself retired.
    #[error("{what} are not supported")]
    Unsupported { what: String },
    /// Protected by a passphrase, and none was given: nothing could ask for
    /// one, or the person asked said no.
    #[error("it needs a passphrase that was not given")]
    Locked,
    /// Every passphrase offered for it was wrong.
    #[error("the passphrase was not accepted")]
    WrongPassphrase,
}

/// What a person is shown when a key needs unlocking.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyDescription {
    /// `SHA256:…`, the form `ssh-keygen -l` prints. `None` for the formats
    /// that keep even the public half behind the passphrase.
    pub fingerprint: Option<String>,
    /// The key's own comment, often `user@host`. Empty when the format
    /// encrypts it along with the key.
    pub comment: String,
}

/// Supplies a passphrase when, and only when, a key needs one.
///
/// Asked from the middle of a login. `attempt` counts from one; a second call
/// for the same key means the first passphrase was wrong.
#[async_trait::async_trait]
pub trait KeyUnlocker: Send + Sync {
    /// `None` is the person declining — a decision, not a wrong passphrase,
    /// and it ends the login without being reported as a failure.
    async fn passphrase(&self, key: &KeyDescription, attempt: u32) -> Option<String>;
}

/// A private key, read.
pub struct PrivateKey {
    material: Material,
    description: KeyDescription,
}

enum Material {
    /// Usable as it is: never encrypted, or decrypted with the passphrase the
    /// caller supplied.
    Ready(ssh_key::PrivateKey),
    /// OpenSSH's format, encrypted. The public half is readable, so the
    /// server can be asked about it before anyone is asked for anything.
    Sealed(ssh_key::PrivateKey),
    /// Encrypted PKCS#8, a legacy PEM or a PuTTY file: nothing is readable
    /// until the passphrase is known, so there is nothing to ask the server
    /// first. Kept as text, because text is what decrypts.
    Opaque(String),
}

/// How unlocking ended when it did not produce a key.
#[derive(Debug)]
pub(crate) enum Unlocking {
    Declined,
    Failed(KeyError),
}

impl PrivateKey {
    /// Reads `text`, decrypting it with `passphrase` if one is given and the
    /// key needs it.
    ///
    /// A locked key without a passphrase is not an error: it is read, and
    /// unlocked later if the login gets as far as it.
    pub fn parse(text: &str, passphrase: Option<&str>) -> Result<Self, KeyError> {
        if text.trim_start().starts_with("-----BEGIN OPENSSH PRIVATE KEY-----") {
            return Self::parse_openssh(text, passphrase);
        }

        match russh::keys::decode_secret_key(text, passphrase) {
            Ok(key) => Self::ready(key),
            Err(error) if looks_encrypted(text, &error) => match passphrase {
                Some(_) => Err(KeyError::WrongPassphrase),
                None => Ok(Self {
                    material: Material::Opaque(text.to_owned()),
                    description: KeyDescription { fingerprint: None, comment: String::new() },
                }),
            },
            Err(error) => Err(KeyError::Unreadable { cause: error.to_string() }),
        }
    }

    fn parse_openssh(text: &str, passphrase: Option<&str>) -> Result<Self, KeyError> {
        let key = ssh_key::PrivateKey::from_openssh(text)
            .map_err(|error| KeyError::Unreadable { cause: error.to_string() })?;
        supported(key.algorithm())?;

        if !key.is_encrypted() {
            return Self::ready(key);
        }
        match passphrase {
            Some(passphrase) => {
                let key = key.decrypt(passphrase).map_err(|_| KeyError::WrongPassphrase)?;
                Self::ready(key)
            }
            None => {
                let description = describe(&key);
                Ok(Self { material: Material::Sealed(key), description })
            }
        }
    }

    fn ready(key: ssh_key::PrivateKey) -> Result<Self, KeyError> {
        supported(key.algorithm())?;
        let description = describe(&key);
        Ok(Self { material: Material::Ready(key), description })
    }

    /// Whether using this key will mean asking for a passphrase.
    pub fn needs_passphrase(&self) -> bool {
        !matches!(self.material, Material::Ready(_))
    }

    pub fn description(&self) -> &KeyDescription {
        &self.description
    }

    /// Whether the passphrase has to be known before the server can be
    /// asked about this key: a format that seals its public half with the rest.
    pub fn unlocks_first(&self) -> bool {
        matches!(self.material, Material::Opaque(_))
    }

    /// This key, opened with a passphrase from `unlocker`.
    ///
    /// For the formats that must be unlocked before the server hears of
    /// them, so that it can happen before the key's turn on a connection: a
    /// person saying no, or every passphrase being wrong, then costs this key
    /// and nothing after it. A decline reads as [`KeyError::Locked`] — the key
    /// stayed locked.
    pub async fn opened(&self, unlocker: &dyn KeyUnlocker) -> Result<PrivateKey, KeyError> {
        match self.unlock(unlocker).await {
            Ok(key) => Self::ready(key),
            Err(Unlocking::Declined) => Err(KeyError::Locked),
            Err(Unlocking::Failed(error)) => Err(error),
        }
    }

    /// The key as the protocol wants it, if it is usable without asking.
    pub(crate) fn ready_key(&self) -> Option<&ssh_key::PrivateKey> {
        match &self.material {
            Material::Ready(key) => Some(key),
            _ => None,
        }
    }

    /// The public half, if it can be read without the passphrase.
    pub(crate) fn sealed_public_key(&self) -> Option<&ssh_key::PublicKey> {
        match &self.material {
            Material::Sealed(key) => Some(key.public_key()),
            _ => None,
        }
    }

    /// Asks `unlocker` for the passphrase, up to [`PASSPHRASE_ATTEMPTS`]
    /// times, and returns the decrypted key.
    pub(crate) async fn unlock(
        &self,
        unlocker: &dyn KeyUnlocker,
    ) -> Result<ssh_key::PrivateKey, Unlocking> {
        if let Material::Ready(key) = &self.material {
            return Ok(key.clone());
        }
        for attempt in 1..=PASSPHRASE_ATTEMPTS {
            let Some(passphrase) = unlocker.passphrase(&self.description, attempt).await else {
                return Err(Unlocking::Declined);
            };
            match self.decrypt(&passphrase) {
                Ok(key) => return Ok(key),
                // Unsupported only comes to light once an opaque key is
                // open; asking again would not change it.
                Err(error @ KeyError::Unsupported { .. }) => return Err(Unlocking::Failed(error)),
                Err(_) => continue,
            }
        }
        Err(Unlocking::Failed(KeyError::WrongPassphrase))
    }

    fn decrypt(&self, passphrase: &str) -> Result<ssh_key::PrivateKey, KeyError> {
        let key = match &self.material {
            Material::Ready(key) => return Ok(key.clone()),
            Material::Sealed(key) => {
                key.decrypt(passphrase).map_err(|_| KeyError::WrongPassphrase)?
            }
            Material::Opaque(text) => russh::keys::decode_secret_key(text, Some(passphrase))
                .map_err(|_| KeyError::WrongPassphrase)?,
        };
        supported(key.algorithm())?;
        Ok(key)
    }
}

impl std::fmt::Debug for PrivateKey {
    /// Hand-written so a `Debug` line can never print key material (§18).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PrivateKey")
            .field("fingerprint", &self.description.fingerprint)
            .field("needs_passphrase", &self.needs_passphrase())
            .finish()
    }
}

/// Signs `data` the way the protocol expects the signature to follow it.
///
/// russh does this itself for a key it holds; for a key unlocked mid-login
/// it hands the bytes to a signer instead, and this is that signer's work.
/// RSA honours the hash the server was probed with — signing with another
/// would be a signature the server rejects for a key it just accepted.
pub(crate) fn sign(
    key: &ssh_key::PrivateKey,
    hash: Option<HashAlg>,
    data: &[u8],
) -> Result<Vec<u8>, String> {
    use russh::keys::signature::Signer;
    use russh::keys::ssh_encoding::Encode;

    let signature: ssh_key::Signature = match key.key_data() {
        ssh_key::private::KeypairData::Rsa(rsa) => Signer::try_sign(&(rsa, hash), data),
        other => Signer::try_sign(other, data),
    }
    .map_err(|error| error.to_string())?;
    signature.encode_vec().map_err(|error| error.to_string())
}

fn describe(key: &ssh_key::PrivateKey) -> KeyDescription {
    KeyDescription {
        fingerprint: Some(key.fingerprint(HashAlg::Sha256).to_string()),
        comment: AsRef::<str>::as_ref(key.comment()).to_owned(),
    }
}

/// The kinds this client can sign with.
fn supported(algorithm: Algorithm) -> Result<(), KeyError> {
    match algorithm {
        Algorithm::Ed25519 | Algorithm::Ecdsa { .. } | Algorithm::Rsa { .. } => Ok(()),
        Algorithm::SkEd25519 | Algorithm::SkEcdsaSha2NistP256 => {
            Err(KeyError::Unsupported { what: "security keys".to_owned() })
        }
        Algorithm::Dsa => Err(KeyError::Unsupported { what: "DSA keys".to_owned() }),
        other => Err(KeyError::Unsupported { what: format!("{} keys", other.as_str()) }),
    }
}

/// Whether a key that did not read without a passphrase is one that might
/// with one.
///
/// russh names only some of these: an encrypted PKCS#8 file fails as a
/// structure it could not parse, so the headers are read here too.
fn looks_encrypted(text: &str, error: &russh::keys::Error) -> bool {
    if matches!(error, russh::keys::Error::KeyIsEncrypted) {
        return true;
    }
    let text = text.trim_start();
    if text.starts_with("-----BEGIN ENCRYPTED PRIVATE KEY-----")
        || text.lines().any(|line| line.trim() == "Proc-Type: 4,ENCRYPTED")
    {
        return true;
    }
    text.starts_with("PuTTY-User-Key-File-")
        && text.lines().any(|line| {
            line.strip_prefix("Encryption:").is_some_and(|value| value.trim() != "none")
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test-only, generated for this file with `ssh-keygen -N 'open sesame'`.
    const LOCKED: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAl68WTMp
POCgCukBERmhH8AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAICFLQcIbWCZXUrqF
37lOOuTVDRTQ9C5mZju8ILB3n011AAAAoFpwrADSZe4I1dSd8NsOGgvE60TsJhksIlmFeA
BluC6I46H4W/ui0uBUdvxzzUwI6agzoWuuHLwZhBSxj3YQjoiqEwTEr03KP1WK8I4bDR85
wg3Q7Mjl+p/ifNa3t3qZq1GxMA1qU64CJBZSRs07GmZV4zf6/jniij+gFHcV4LjyzkLlYg
AWHhZ6RyEnRGObeD10W92qL7HBfyHaMUGL9ko=
-----END OPENSSH PRIVATE KEY-----
";

    /// The same key in encrypted PKCS#8, which hides the public half too.
    ///
    /// Written by russh rather than checked in: `ssh-keygen -m PKCS8` on
    /// macOS derives its key with PBKDF2-HMAC-SHA1, which the PKCS#8 stack
    /// underneath refuses — a limit of the upstream crate, surfaced to a
    /// person as a passphrase that never works, and not ours to rewrite.
    fn pkcs8() -> String {
        let key = russh::keys::decode_secret_key(LOCKED, Some("open sesame")).expect("fixture");
        let mut pem = Vec::new();
        russh::keys::encode_pkcs8_pem_encrypted(&key, b"open sesame", 16, &mut pem)
            .expect("encode");
        String::from_utf8(pem).expect("pem is text")
    }

    struct Script(std::sync::Mutex<Vec<Option<&'static str>>>);

    #[async_trait::async_trait]
    impl KeyUnlocker for Script {
        async fn passphrase(&self, _: &KeyDescription, _: u32) -> Option<String> {
            let mut answers = self.0.lock().unwrap();
            if answers.is_empty() { None } else { answers.remove(0).map(str::to_owned) }
        }
    }

    #[test]
    fn a_locked_openssh_key_shows_its_public_half_before_it_is_unlocked() {
        let key = PrivateKey::parse(LOCKED, None).expect("read");
        assert!(key.needs_passphrase());
        assert_eq!(
            key.description().fingerprint.as_deref(),
            Some("SHA256:geKjwKwJQtGRfWN+mIqt0nKBY/0SsaLfiVYpvHUCKKc")
        );
        assert!(key.sealed_public_key().is_some());
    }

    #[test]
    fn a_supplied_passphrase_unlocks_up_front_and_a_wrong_one_is_named() {
        assert!(!PrivateKey::parse(LOCKED, Some("open sesame")).expect("read").needs_passphrase());
        assert_eq!(PrivateKey::parse(LOCKED, Some("nope")).unwrap_err(), KeyError::WrongPassphrase);
    }

    #[test]
    fn encrypted_pkcs8_is_read_as_locked_with_nothing_to_show() {
        let pkcs8 = pkcs8();
        assert!(pkcs8.starts_with("-----BEGIN ENCRYPTED PRIVATE KEY-----"));
        let key = PrivateKey::parse(&pkcs8, None).expect("read");
        assert!(key.needs_passphrase());
        assert_eq!(key.description().fingerprint, None);
        assert!(key.sealed_public_key().is_none(), "nothing to probe the server with");
        assert!(!PrivateKey::parse(&pkcs8, Some("open sesame")).expect("read").needs_passphrase());
        assert_eq!(PrivateKey::parse(&pkcs8, Some("nope")).unwrap_err(), KeyError::WrongPassphrase);
    }

    #[test]
    fn something_that_is_not_a_key_is_unreadable_not_a_panic() {
        assert!(matches!(
            PrivateKey::parse("PRIVATE MATERIAL", None),
            Err(KeyError::Unreadable { .. })
        ));
        assert!(matches!(
            PrivateKey::parse(
                "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n",
                None
            ),
            Err(KeyError::Unreadable { .. })
        ));
    }

    #[test]
    fn a_security_key_is_left_out_by_name() {
        assert_eq!(
            supported(Algorithm::SkEd25519),
            Err(KeyError::Unsupported { what: "security keys".to_owned() })
        );
        assert!(supported(Algorithm::Ed25519).is_ok());
    }

    #[tokio::test]
    async fn three_wrong_passphrases_give_up_and_a_decline_is_a_decline() {
        let key = PrivateKey::parse(LOCKED, None).expect("read");

        let wrong = Script(std::sync::Mutex::new(vec![
            Some("a"),
            Some("b"),
            Some("c"),
            Some("open sesame"),
        ]));
        assert!(matches!(
            key.unlock(&wrong).await,
            Err(Unlocking::Failed(KeyError::WrongPassphrase))
        ));
        assert_eq!(wrong.0.lock().unwrap().len(), 1, "a fourth was never asked for");

        let declined = Script(std::sync::Mutex::new(vec![Some("a"), None]));
        assert!(matches!(key.unlock(&declined).await, Err(Unlocking::Declined)));

        let right = Script(std::sync::Mutex::new(vec![Some("wrong"), Some("open sesame")]));
        assert!(key.unlock(&right).await.is_ok());
    }
}
