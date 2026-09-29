//! Keys that cannot be used, and keys that need a passphrase, in a whole
//! login — against the in-process fake host, over a loopback socket.
//!
//! The question these answer is the one a person asks when a login fails:
//! was my key even tried? A key the client could not read used to end the
//! login where it stood, taking every credential after it down with it.

#[allow(dead_code)]
#[path = "../../tether-ssh/tests/support/mod.rs"]
mod support;

use std::sync::{Arc, Mutex};

use tether_core::ssh::{Endpoint, KeyDescription, KeyError, KeyUnlocker, Prompter};
use tether_core::terminal::ScreenSize;
use tether_core::{Credential, Dial, DialError};

use support::{CLIENT_KEY, CLIENT_PUBLIC_KEY, LOCKED_KEY, LOCKED_PASSPHRASE, LOCKED_PUBLIC_KEY};

async fn dial(policy: support::Policy) -> (Dial, Arc<Mutex<support::Observed>>) {
    let (address, observed) = support::listen(policy).await;
    let dial = Dial::new(Endpoint::new(address.ip().to_string(), address.port()), support::USER)
        .verifier(Arc::new(support::TrustAndRecord::new()))
        .config(support::client_config())
        .size(ScreenSize::new(80, 24));
    (dial, observed)
}

fn key(pem: &str) -> Credential {
    Credential::PrivateKey { pem: pem.to_owned(), passphrase: None, unlock: None }
}

fn locked(unlock: &Arc<Counting>) -> Credential {
    Credential::PrivateKey {
        pem: LOCKED_KEY.to_owned(),
        passphrase: None,
        unlock: Some(Arc::clone(unlock) as Arc<dyn KeyUnlocker>),
    }
}

fn interactive(answers: impl IntoIterator<Item = Vec<String>>) -> Credential {
    Credential::Interactive(Arc::new(support::ScriptedPrompter::new(answers)) as Arc<dyn Prompter>)
}

/// Answers from a script, and counts the questions.
struct Counting {
    answers: Mutex<Vec<Option<&'static str>>>,
    asked: Mutex<u32>,
}

impl Counting {
    fn new(answers: impl IntoIterator<Item = Option<&'static str>>) -> Arc<Self> {
        Arc::new(Self { answers: Mutex::new(answers.into_iter().collect()), asked: Mutex::new(0) })
    }
    fn asked(&self) -> u32 {
        *self.asked.lock().unwrap()
    }
}

#[async_trait::async_trait]
impl KeyUnlocker for Counting {
    async fn passphrase(&self, _: &KeyDescription, _: u32) -> Option<String> {
        *self.asked.lock().unwrap() += 1;
        let mut answers = self.answers.lock().unwrap();
        if answers.is_empty() { None } else { answers.remove(0).map(str::to_owned) }
    }
}

/// The failure this file exists for: a file that is not a key sat first in
/// the list, and the password after it was never reached.
#[tokio::test]
async fn a_key_that_cannot_be_read_is_left_out_and_the_rest_are_still_offered() {
    let (dial, _) = dial(support::Policy::default()).await;

    let session = dial
        .connect(vec![
            key("-----BEGIN OPENSSH PRIVATE KEY-----\nnot a key\n-----END OPENSSH PRIVATE KEY-----\n"),
            interactive([vec![support::PASSWORD.to_owned()]]),
        ])
        .await
        .expect("the password after the broken key logs in");
    session.close().await.expect("closes");
}

/// When the login does fail, the key that was left out is part of the
/// answer — named by where it sat, so the caller can name the file.
#[tokio::test]
async fn a_refused_login_says_which_key_was_left_out_and_why() {
    let (dial, _) = dial_refusing().await;
    match dial.connect(vec![key("PRIVATE MATERIAL"), key(CLIENT_KEY)]).await {
        Err(DialError::Refused { skipped, .. }) => {
            assert_eq!(skipped.len(), 1);
            assert_eq!(skipped[0].position, 0);
            assert!(matches!(skipped[0].problem, KeyError::Unreadable { .. }));
        }
        other => panic!("expected Refused with a skipped key, got {other:?}"),
    }
}

async fn dial_refusing() -> (Dial, Arc<Mutex<support::Observed>>) {
    // Accepts a key nobody here holds, so every key offered is refused.
    dial(support::Policy { accepts_key: Some(LOCKED_PUBLIC_KEY), ..support::Policy::default() })
        .await
}

/// Nothing usable means nothing is dialled: no host key question, no
/// connection opened for nothing.
#[tokio::test]
async fn nothing_usable_is_said_before_anything_is_dialled() {
    let unreachable = Dial::new(Endpoint::new("192.0.2.1", 22), "nobody");

    match unreachable.connect(vec![key("PRIVATE MATERIAL")]).await {
        Err(DialError::Unusable { skipped }) => {
            assert_eq!(skipped.len(), 1);
            assert_eq!(skipped[0].position, 0);
            assert_eq!(skipped[0].fingerprint, None);
            assert!(matches!(skipped[0].problem, KeyError::Unreadable { .. }));
        }
        other => panic!("expected Unusable before dialling, got {other:?}"),
    }
}

/// A locked key with nothing to ask for its passphrase is left out by name,
/// with its fingerprint — the public half is readable.
#[tokio::test]
async fn a_locked_key_with_no_way_to_ask_is_left_out_with_its_fingerprint() {
    let (dial, _) = dial_refusing().await;

    match dial.connect(vec![key(LOCKED_KEY), key(CLIENT_KEY)]).await {
        Err(DialError::Refused { skipped, .. }) => {
            assert_eq!(skipped.len(), 1);
            assert_eq!(skipped[0].problem, KeyError::Locked);
            assert_eq!(
                skipped[0].fingerprint.as_deref(),
                Some("SHA256:geKjwKwJQtGRfWN+mIqt0nKBY/0SsaLfiVYpvHUCKKc")
            );
        }
        other => panic!("expected Refused naming the locked key, got {other:?}"),
    }
}

#[tokio::test]
async fn a_locked_key_the_server_wants_is_unlocked_and_logs_in() {
    let (dial, _) = dial(support::Policy {
        accepts_key: Some(LOCKED_PUBLIC_KEY),
        ..support::Policy::default()
    })
    .await;
    let unlock = Counting::new([Some(LOCKED_PASSPHRASE)]);

    let session = dial.connect(vec![locked(&unlock)]).await.expect("unlocked and accepted");
    assert_eq!(unlock.asked(), 1);
    session.close().await.expect("closes");
}

/// The server said no to the public half, so nobody is asked; the next
/// credential is.
#[tokio::test]
async fn a_locked_key_the_server_does_not_want_asks_nobody() {
    let (dial, _) = dial(support::Policy {
        accepts_key: Some(CLIENT_PUBLIC_KEY),
        ..support::Policy::default()
    })
    .await;
    let unlock = Counting::new([Some(LOCKED_PASSPHRASE)]);

    let session =
        dial.connect(vec![locked(&unlock), key(CLIENT_KEY)]).await.expect("the second key logs in");
    assert_eq!(unlock.asked(), 0, "never asked for a key the server would not take");
    session.close().await.expect("closes");
}

/// Declining is the person's no: it ends the login as a decline, exactly as
/// closing an interactive prompt does.
#[tokio::test]
async fn declining_the_passphrase_ends_the_login_as_a_decline() {
    let (dial, _) = dial(support::Policy {
        accepts_key: Some(LOCKED_PUBLIC_KEY),
        ..support::Policy::default()
    })
    .await;
    let unlock = Counting::new([None]);

    match dial
        .connect(vec![locked(&unlock), interactive([vec![support::PASSWORD.to_owned()]])])
        .await
    {
        Err(DialError::Ssh(tether_core::ssh::SshError::Declined)) => {}
        other => panic!("expected a decline, got {other:?}"),
    }
}

/// Three wrong passphrases end the login, naming the key and the reason.
#[tokio::test]
async fn three_wrong_passphrases_name_the_key() {
    let (dial, _) = dial(support::Policy {
        accepts_key: Some(LOCKED_PUBLIC_KEY),
        ..support::Policy::default()
    })
    .await;
    let unlock = Counting::new([Some("one"), Some("two"), Some("three")]);

    match dial.connect(vec![locked(&unlock)]).await {
        Err(DialError::Unusable { skipped }) => {
            assert_eq!(skipped.len(), 1);
            assert_eq!(skipped[0].position, 0);
            assert_eq!(skipped[0].problem, KeyError::WrongPassphrase);
            assert!(skipped[0].fingerprint.is_some());
        }
        other => panic!("expected the key named as unusable, got {other:?}"),
    }
    assert_eq!(unlock.asked(), 3);
}

/// A passphrase given up front is used without asking anyone.
#[tokio::test]
async fn a_supplied_passphrase_is_used_without_asking() {
    let (dial, _) = dial(support::Policy {
        accepts_key: Some(LOCKED_PUBLIC_KEY),
        ..support::Policy::default()
    })
    .await;

    let session = dial
        .connect(vec![Credential::PrivateKey {
            pem: LOCKED_KEY.to_owned(),
            passphrase: Some(LOCKED_PASSPHRASE.to_owned()),
            unlock: None,
        }])
        .await
        .expect("the supplied passphrase unlocks it");
    session.close().await.expect("closes");
}

/// A key sealed whole — PKCS#8, a legacy PEM — has to be unlocked before
/// the server can be asked about it. Saying no to that costs only that key:
/// nothing about it reached the server, so the password after it still logs in.
#[tokio::test]
async fn declining_a_key_that_must_be_unlocked_first_leaves_only_that_key_out() {
    let mut pem = Vec::new();
    let sealed =
        russh::keys::decode_secret_key(LOCKED_KEY, Some(LOCKED_PASSPHRASE)).expect("fixture");
    russh::keys::encode_pkcs8_pem_encrypted(&sealed, b"open sesame", 16, &mut pem)
        .expect("encrypted");
    let unlock = Counting::new([None]);
    let (dial, _) = dial(support::Policy::default()).await;

    let session = dial
        .connect(vec![
            Credential::PrivateKey {
                pem: String::from_utf8(pem).expect("pem"),
                passphrase: None,
                unlock: Some(Arc::clone(&unlock) as Arc<dyn KeyUnlocker>),
            },
            interactive([vec![support::PASSWORD.to_owned()]]),
        ])
        .await
        .expect("the password after the declined key logs in");
    assert_eq!(unlock.asked(), 1);
    session.close().await.expect("closes");
}
