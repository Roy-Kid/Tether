//! Offering credentials in order, against a real server.
//!
//! The branching this covers is the reason the crate exists: a server that
//! accepts a factor and wants another is not a failure, a server that refuses
//! one is, and telling a person the wrong one of those is worse than telling
//! them nothing. None of that is visible from a single successful login, so
//! the wrong credentials are offered here deliberately.
//!
//! Skipped when no server is configured; see `tests/session.rs`.

use std::sync::Arc;

use tether_core::ssh::{Endpoint, HostKey, HostVerifier, Verdict};
use tether_core::terminal::ScreenSize;
use tether_core::{Credential, Dial, DialError};

struct TrustTestServer;

#[async_trait::async_trait]
impl HostVerifier for TrustTestServer {
    async fn verify(&self, _: &Endpoint, _: &HostKey) -> Verdict {
        Verdict::Trusted
    }
}

struct Server {
    endpoint: Endpoint,
    user: String,
    key: String,
}

fn server() -> Option<Server> {
    Some(Server {
        endpoint: Endpoint::new(
            std::env::var("TETHER_TEST_SSH_HOST").ok()?,
            std::env::var("TETHER_TEST_SSH_PORT").ok()?.parse().ok()?,
        ),
        user: std::env::var("TETHER_TEST_SSH_USER").ok()?,
        key: std::fs::read_to_string(std::env::var("TETHER_TEST_SSH_KEY").ok()?).ok()?,
    })
}

macro_rules! server_or_skip {
    () => {
        match server() {
            Some(server) => server,
            None => {
                eprintln!("skipped: TETHER_TEST_SSH_* not set");
                return;
            }
        }
    };
}

fn dial(server: &Server) -> Dial {
    Dial::new(server.endpoint.clone(), server.user.clone())
        .verifier(Arc::new(TrustTestServer))
        .size(ScreenSize::new(80, 24))
}

/// Offering nothing is its own answer, not a refusal by the server. Reporting
/// it as an authentication failure would send someone looking for a typo in a
/// password they never gave.
#[tokio::test]
async fn offering_nothing_is_not_an_authentication_failure() {
    let server = server_or_skip!();

    let outcome = dial(&server).connect(vec![]).await;

    assert!(
        matches!(outcome, Err(DialError::NothingToOffer)),
        "expected NothingToOffer, got {outcome:?}"
    );
}

/// A credential the server will not take is reported with what it *would*
/// take, so a consumer can say "this host wants a key" instead of "failed".
#[tokio::test]
async fn a_refused_credential_reports_what_the_server_still_wants() {
    let server = server_or_skip!();

    let outcome =
        dial(&server).connect(vec![Credential::Password("not the password".into())]).await;

    match outcome {
        Err(DialError::Refused { remaining, .. }) => {
            assert!(
                remaining.iter().any(|method| method == "publickey"),
                "the test server accepts keys and should say so: {remaining:?}"
            );
        }
        other => panic!("expected Refused, got {other:?}"),
    }
}

/// The offer is a sequence, not a single guess: a credential the server
/// refuses must not end the attempt while others are left.
#[tokio::test]
async fn a_later_credential_is_reached_after_an_earlier_one_is_refused() {
    let server = server_or_skip!();

    let session = dial(&server)
        .connect(vec![
            Credential::Password("wrong".into()),
            Credential::PrivateKey { pem: server.key.clone(), passphrase: None, unlock: None },
        ])
        .await
        .expect("the key should be reached and accepted");

    assert!(session.ending().is_none(), "a fresh session is running");
    session.close().await.expect("closes cleanly");
}

/// An unusable key is a complaint about the key itself, not a rejection by
/// the server — nothing was offered to it, and nothing was dialled for it.
#[tokio::test]
async fn a_key_that_cannot_be_parsed_says_so_rather_than_blaming_the_server() {
    let server = server_or_skip!();

    let outcome = dial(&server)
        .connect(vec![Credential::PrivateKey {
            pem: "-----BEGIN OPENSSH PRIVATE KEY-----\nnot a key\n".into(),
            passphrase: None,
            unlock: None,
        }])
        .await;

    match outcome {
        Err(DialError::Unusable { skipped }) => {
            assert_eq!(skipped.len(), 1);
            assert!(
                matches!(skipped[0].problem, tether_core::ssh::KeyError::Unreadable { .. }),
                "unhelpful: {:?}",
                skipped[0].problem
            );
        }
        other => panic!("expected the key named as unusable, got {other:?}"),
    }
}

/// Credentials are secret; the `Debug` that would print them in a log is not
/// something to leave to chance (spec §18).
#[test]
fn a_credential_never_prints_what_it_holds() {
    let password = Credential::Password("hunter2".into());
    let key = Credential::PrivateKey {
        pem: "PRIVATE MATERIAL".into(),
        passphrase: Some("s".into()),
        unlock: None,
    };

    for credential in [&password, &key] {
        let printed = format!("{credential:?}");
        assert!(!printed.contains("hunter2"), "leaked: {printed}");
        assert!(!printed.contains("PRIVATE MATERIAL"), "leaked: {printed}");
    }

    assert_eq!(format!("{password:?}"), "Credential::Password");
    assert_eq!(format!("{key:?}"), "Credential::PrivateKey");
}
