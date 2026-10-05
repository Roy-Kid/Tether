//! Credentials that never reach a server.
//!
//! An empty offer and a key that cannot be read are answered before anything
//! is dialled. What a real server does with a password is not this suite.

use tether_core::ssh::Endpoint;
use tether_core::{Credential, Dial, DialError};

fn dial() -> Dial {
    Dial::new(Endpoint::new("127.0.0.1", 1), "nobody")
}

/// Offering nothing is its own answer, not a refusal by the server. Reporting
/// it as an authentication failure would send someone looking for a typo in a
/// password they never gave.
#[tokio::test]
async fn offering_nothing_is_not_an_authentication_failure() {
    let outcome = dial().connect(vec![]).await;

    assert!(
        matches!(outcome, Err(DialError::NothingToOffer)),
        "expected NothingToOffer, got {outcome:?}"
    );
}

/// An unusable key is a complaint about the key itself, not a rejection by
/// the server — nothing was offered to it, and nothing was dialled for it.
#[tokio::test]
async fn a_key_that_cannot_be_parsed_says_so_rather_than_blaming_the_server() {
    let outcome = dial()
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
