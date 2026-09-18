//! The Phase 1 contract: reach a host that *requires* interactive
//! authentication, prove who you are, hold a shell, resize it, and leave
//! cleanly.

mod support;

use std::sync::Arc;

use support::{BANNER, CLIENT_KEY, CLIENT_PUBLIC_KEY, ONE_TIME_CODE, PASSWORD, Policy, USER};
use tether_ssh::{Connection, Endpoint, Output, SshError, Step, WindowSize};

fn endpoint() -> Endpoint {
    Endpoint::new("fake.cluster", 22)
}

async fn connect(policy: Policy) -> (Connection, Arc<std::sync::Mutex<support::Observed>>) {
    let (stream, observed) = support::start(policy);
    let connection = Connection::connect_over(
        endpoint(),
        stream,
        Arc::new(support::TrustAndRecord::new()),
        support::client_config(),
    )
    .await
    .expect("handshake");
    (connection, observed)
}

/// The whole point of Phase 1, in one test.
#[tokio::test]
async fn logs_in_interactively_holds_a_shell_resizes_it_and_disconnects() {
    let (connection, observed) = connect(Policy { two_factor: true, ..Policy::default() }).await;

    // The server refuses passwords, so a password-only client stops here.
    let connection = match connection.password(USER, PASSWORD).await.expect("attempt") {
        Step::Rejected { remaining, retry } => {
            assert!(
                remaining.iter().any(|m| m.to_string() == "keyboard-interactive"),
                "server should have pointed us at keyboard-interactive, said {remaining:?}"
            );
            retry
        }
        other => panic!("password should have been refused, got {other:?}"),
    };

    // Two rounds, the second of which the server only asks for after the
    // first is accepted.
    let prompter = support::ScriptedPrompter::new([
        vec![PASSWORD.to_string()],
        vec![ONE_TIME_CODE.to_string()],
    ]);
    let session = match connection.interactive(USER, &prompter).await.expect("exchange") {
        Step::Authenticated(session) => session,
        other => panic!("interactive auth should have succeeded, got {other:?}"),
    };

    // The server's own wording reached us unparsed, echo flags intact.
    let asked = prompter.seen.lock().unwrap().clone();
    assert_eq!(asked.len(), 2, "server drove two rounds");
    assert_eq!(asked[0].name, "Cluster login");
    assert_eq!(asked[0].prompts[0].text, "Password: ");
    assert!(!asked[0].prompts[0].echo, "a password must not echo");
    assert!(asked[1].prompts[0].echo, "this server echoes its code prompt");

    // A shell, with a pty the far side actually received.
    let mut shell = session.shell("xterm-256color", WindowSize::new(120, 40)).await.expect("shell");

    assert_eq!(observed.lock().unwrap().pty_term.as_deref(), Some("xterm-256color"));
    assert_eq!(observed.lock().unwrap().pty_size, Some((120, 40)));

    assert_eq!(read_text(&mut shell).await, BANNER);

    shell.write("echo hello\n".as_bytes().to_vec()).await.expect("write");
    assert_eq!(read_text(&mut shell).await, "echo hello\n");

    // Resize, and observe it from both ends.
    shell.resize(WindowSize::new(80, 24)).await.expect("resize");
    assert_eq!(read_text(&mut shell).await, "resized 80x24\r\n");
    assert_eq!(observed.lock().unwrap().resizes, vec![(80, 24)]);
    assert_eq!(shell.size(), WindowSize::new(80, 24));

    shell.close().await.expect("close");
    session.disconnect().await.expect("disconnect");
}

/// Abandoning a prompt is a decision, not a wrong password. Telling someone
/// their credentials failed when they simply closed a dialog is a lie the
/// error model has to prevent.
#[tokio::test]
async fn declining_is_not_an_authentication_failure() {
    let (connection, _) = connect(Policy { two_factor: true, ..Policy::default() }).await;
    let prompter = support::ScriptedPrompter::new([]);

    match connection.interactive(USER, &prompter).await {
        Err(SshError::Declined) => {}
        other => panic!("expected Declined, got {other:?}"),
    }
}

/// A wrong answer must not cost the connection: someone mistypes a code and
/// should get another go without a fresh handshake.
#[tokio::test]
async fn a_wrong_answer_leaves_the_connection_usable() {
    let (connection, _) = connect(Policy::default()).await;

    let wrong = support::ScriptedPrompter::new([vec!["not the password".to_string()]]);
    let connection = match connection.interactive(USER, &wrong).await.expect("attempt") {
        Step::Rejected { retry, .. } => retry,
        other => panic!("a wrong password should be rejected, got {other:?}"),
    };

    let right = support::ScriptedPrompter::new([vec![PASSWORD.to_string()]]);
    match connection.interactive(USER, &right).await.expect("retry") {
        Step::Authenticated(session) => session.disconnect().await.expect("disconnect"),
        other => panic!("retry should have succeeded, got {other:?}"),
    }
}

/// A refused host key is not an authentication failure either, and must not
/// be reported as one: the remedy is checking a fingerprint, not retyping a
/// password.
#[tokio::test]
async fn an_untrusted_host_is_refused_before_any_credential() {
    let (stream, observed) = support::start(Policy::default());

    match Connection::connect_over(
        endpoint(),
        stream,
        Arc::new(tether_ssh::RejectAll),
        support::client_config(),
    )
    .await
    {
        Err(SshError::HostRejected { endpoint }) => assert_eq!(endpoint, "fake.cluster:22"),
        other => panic!("expected HostRejected, got {:?}", other.map(|_| "connected")),
    }

    assert_eq!(
        observed.lock().unwrap().password_attempts,
        0,
        "nothing may be offered to a host we refused"
    );
}

/// The verifier sees a fingerprint in the form a person can compare against
/// what their administrator published.
#[tokio::test]
async fn the_verifier_is_shown_a_recognisable_fingerprint() {
    let (stream, _) = support::start(Policy::default());
    let verifier = Arc::new(support::TrustAndRecord::new());

    let connection =
        Connection::connect_over(endpoint(), stream, verifier.clone(), support::client_config())
            .await
            .expect("handshake");

    let seen = verifier.seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].algorithm, "ssh-ed25519");
    assert_eq!(seen[0].fingerprint, support::HOST_FINGERPRINT);
    assert!(String::from_utf8_lossy(&seen[0].encoded).starts_with("ssh-ed25519 "));

    drop(connection);
}

/// Asking what a server accepts must not disclose anything.
#[tokio::test]
async fn offered_methods_can_be_read_without_offering_a_credential() {
    let (connection, _) = connect(Policy::default()).await;

    match connection.offered_methods(USER).await.expect("probe") {
        Step::Rejected { remaining, .. } => assert!(
            remaining.iter().any(|m| m.to_string() == "keyboard-interactive"),
            "expected keyboard-interactive among {remaining:?}"
        ),
        other => panic!("a bare probe should not authenticate, got {other:?}"),
    }
}

async fn read_text(shell: &mut tether_ssh::Shell) -> String {
    match shell.next_output().await {
        Some(Output::Stdout(bytes)) => String::from_utf8_lossy(&bytes).into_owned(),
        other => panic!("expected stdout, got {other:?}"),
    }
}

/// The third authentication family. A key is not a password with better
/// hygiene: nothing is typed, so there is no prompt to answer.
#[tokio::test]
async fn a_private_key_authenticates() {
    let (connection, observed) =
        connect(Policy { accepts_key: Some(CLIENT_PUBLIC_KEY), ..Policy::default() }).await;

    match connection.private_key(USER, CLIENT_KEY, None).await.expect("attempt") {
        Step::Authenticated(session) => session.disconnect().await.expect("disconnect"),
        other => panic!("the key should have been accepted, got {other:?}"),
    }
    assert!(observed.lock().unwrap().public_key_attempts >= 1);
}

/// An unknown key is refused without costing the connection, and the server
/// says what it would take instead.
#[tokio::test]
async fn an_unknown_key_is_refused_and_the_server_says_what_it_wants() {
    let (connection, _) = connect(Policy::default()).await;

    match connection.private_key(USER, CLIENT_KEY, None).await.expect("attempt") {
        Step::Rejected { remaining, .. } => assert!(
            remaining.iter().any(|m| m.to_string() == "keyboard-interactive"),
            "expected keyboard-interactive among {remaining:?}"
        ),
        other => panic!("an unauthorised key should be refused, got {other:?}"),
    }
}

/// A key *and* a one-time code — the arrangement most research clusters use,
/// and the reason a partial success is not a failure. Reporting this as
/// "authentication failed" would strand every such login.
///
/// Ignored against russh 0.63.3, which cannot *emit* a partial success: its
/// server assigns the handler's flag and then overwrites it with `false` on
/// the next line, in all four rejection paths. That is a defect in russh's
/// server role, which Tether uses only in this fake host — the client code
/// under test here is unaffected, and passes once the server can express what
/// the test needs. Fixed upstream in warp-tech/russh#773 (`dddf72c`,
/// 2026-09-13), unreleased as of 0.63.3; verified against `main`, where this
/// test passes. Re-enable on the release that carries it.
#[ignore = "needs russh > 0.63.3 (warp-tech/russh#773); passes against main"]
#[tokio::test]
async fn a_key_accepted_as_a_first_factor_leads_to_a_second() {
    let (connection, _) = connect(Policy {
        accepts_key: Some(CLIENT_PUBLIC_KEY),
        key_is_only_the_first_factor: true,
        two_factor: false,
    })
    .await;

    let connection = match connection.private_key(USER, CLIENT_KEY, None).await.expect("attempt") {
        Step::AnotherFactor { remaining, next } => {
            assert!(
                remaining.iter().any(|m| m.to_string() == "keyboard-interactive"),
                "expected keyboard-interactive among {remaining:?}"
            );
            next
        }
        other => panic!("expected a partial success, got {other:?}"),
    };

    let prompter = support::ScriptedPrompter::new([vec![PASSWORD.to_string()]]);
    match connection.interactive(USER, &prompter).await.expect("second factor") {
        Step::Authenticated(session) => session.disconnect().await.expect("disconnect"),
        other => panic!("the second factor should have completed login, got {other:?}"),
    }
}

#[tokio::test]
async fn command_channels_are_independent_of_shell_lifetime() {
    let (connection, _) = connect(Policy::default()).await;
    let prompter = support::ScriptedPrompter::new([vec![PASSWORD.to_string()]]);
    let session = match connection.interactive(USER, &prompter).await.unwrap() {
        Step::Authenticated(session) => session,
        other => panic!("unexpected authentication: {other:?}"),
    };
    let mut shell = session.shell("xterm-256color", WindowSize::default()).await.unwrap();
    assert_eq!(read_text(&mut shell).await, BANNER);
    let mut command = session.exec("fixture command").await.unwrap();
    assert_eq!(read_text(&mut command).await, "fixture command");
    shell.write(b"still alive".to_vec()).await.unwrap();
    assert_eq!(read_text(&mut shell).await, "still alive");
    shell.close().await.unwrap();
    let mut next = session.exec("after shell closed").await.unwrap();
    assert_eq!(read_text(&mut next).await, "after shell closed");
}
