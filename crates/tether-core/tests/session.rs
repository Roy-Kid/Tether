//! The whole composition against a real SSH server.
//!
//! `tether-ssh` proves its client against an in-process peer that speaks
//! russh on both sides. That is the right test for the protocol, and the
//! wrong one for this crate: what is being checked here is that a byte
//! stream produced by software we did not write lands on a screen, which
//! means the far side has to be software we did not write.
//!
//! Skipped, not failed, when no server is configured. A test that quietly
//! passes because it did nothing is worse than one that says it was skipped,
//! so this prints why (spec §15).
//!
//! To run it:
//!
//! ```text
//! scripts/test-server.sh start     # prints the exports to set
//! cargo test -p tether-core
//! ```

use std::sync::Arc;
use std::time::Duration;

use tether_core::ssh::{Endpoint, HostKey, HostVerifier, Verdict};
use tether_core::terminal::ScreenSize;
use tether_core::terminal::Scroll;
use tether_core::{Credential, Dial, Ending, TerminalSession};

/// Trusts whatever the test server presents.
///
/// Safe only because the endpoint comes from this test's own environment. A
/// verifier like this has no business outside a test, which is why
/// `tether-ssh` ships `RejectAll` and nothing else (spec §18).
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

/// Reads the server's coordinates, or explains why the test is not running.
fn server() -> Option<Server> {
    let host = std::env::var("TETHER_TEST_SSH_HOST").ok()?;
    let port = std::env::var("TETHER_TEST_SSH_PORT").ok()?.parse().ok()?;
    let user = std::env::var("TETHER_TEST_SSH_USER").ok()?;
    let key_path = std::env::var("TETHER_TEST_SSH_KEY").ok()?;
    let key = std::fs::read_to_string(&key_path).ok()?;

    Some(Server { endpoint: Endpoint::new(host, port), user, key })
}

macro_rules! server_or_skip {
    () => {
        match server() {
            Some(server) => server,
            None => {
                eprintln!("skipped: TETHER_TEST_SSH_* not set (see scripts/test-server.sh)");
                return;
            }
        }
    };
}

async fn connect(server: Server, size: ScreenSize) -> TerminalSession {
    Dial::new(server.endpoint, server.user)
        .verifier(Arc::new(TrustTestServer))
        .size(size)
        .term("xterm-256color")
        .connect(vec![Credential::PrivateKey { pem: server.key, passphrase: None }])
        .await
        .expect("the test server should accept the test key")
}

/// Waits until `predicate` holds, or gives up.
///
/// Time-bounded rather than change-bounded: a shell's banner may arrive in
/// one write or five, and asserting on a fixed number of frames would be
/// asserting on the network's mood.
async fn settle(session: &TerminalSession, what: &str, predicate: impl Fn(&str) -> bool) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);

    loop {
        let text = session.screen().text();
        if predicate(&text) {
            return text;
        }

        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            panic!("timed out waiting for {what}; the screen held:\n{text}");
        }

        if tokio::time::timeout(remaining, session.changed()).await != Ok(true) {
            let text = session.screen().text();
            panic!("the session ended while waiting for {what}; the screen held:\n{text}");
        }
    }
}

#[tokio::test]
async fn a_shell_prompt_reaches_the_screen() {
    let server = server_or_skip!();
    let session = connect(server, ScreenSize::new(80, 24)).await;

    // Not asserting on a prompt's appearance: it is whatever the person's
    // shell is configured to print. That *something* arrives and lands on
    // the screen is the claim being made.
    let text =
        settle(&session, "any output at all", |text| text.chars().any(|c| !c.is_whitespace()))
            .await;

    assert!(!text.trim().is_empty());
    session.close().await.expect("the session should close cleanly");
}

#[tokio::test]
async fn what_is_typed_is_executed_and_its_output_comes_back() {
    let server = server_or_skip!();
    let session = connect(server, ScreenSize::new(80, 24)).await;

    settle(&session, "the shell to be ready", |text| text.chars().any(|c| !c.is_whitespace()))
        .await;

    // A string no prompt would contain by accident, so finding it on screen
    // means the round trip happened rather than that something echoed.
    session.write(b"echo tether-round-trip-4f2a\n".to_vec()).expect("the session is live");

    let text = settle(&session, "the command's output", |text| {
        // Twice: once echoed by the PTY as it was typed, once as output. One
        // occurrence would mean the echo arrived and the command did not run.
        text.matches("tether-round-trip-4f2a").count() >= 2
    })
    .await;

    assert!(text.contains("tether-round-trip-4f2a"));
    session.close().await.expect("the session should close cleanly");
}

#[tokio::test]
async fn the_far_side_is_told_when_the_window_changes_size() {
    let server = server_or_skip!();
    let session = connect(server, ScreenSize::new(80, 24)).await;

    settle(&session, "the shell to be ready", |text| text.chars().any(|c| !c.is_whitespace()))
        .await;

    session.resize(ScreenSize::new(100, 30)).expect("the session is live");
    assert_eq!(session.size(), ScreenSize::new(100, 30), "the engine resized");

    // `tput cols` asks the *far side's* tty, so it can only answer 100 if the
    // window-change request actually crossed the wire. Checking our own
    // `size()` alone would pass even if nothing had been sent.
    session.write(b"tput cols\n".to_vec()).expect("the session is live");

    settle(&session, "the far side to report its width", |text| text.contains("100")).await;

    session.close().await.expect("the session should close cleanly");
}

#[tokio::test]
async fn exiting_the_shell_ends_the_session_with_its_status() {
    let server = server_or_skip!();
    let session = connect(server, ScreenSize::new(80, 24)).await;

    settle(&session, "the shell to be ready", |text| text.chars().any(|c| !c.is_whitespace()))
        .await;

    session.write(b"exit 7\n".to_vec()).expect("the session is live");

    // Drains to the end rather than sleeping: `changed` returns false exactly
    // once there is nothing more coming.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while tokio::time::timeout_at(deadline, session.changed()).await == Ok(true) {}

    assert_eq!(
        session.ending(),
        Some(Ending::Exited(7)),
        "the status the shell chose should survive to the consumer"
    );
}

/// Scrollback, against a shell that really produced the output.
#[tokio::test]
async fn output_that_scrolled_away_can_be_read_again() {
    let server = server_or_skip!();
    let session = connect(server, ScreenSize::new(80, 10)).await;

    settle(&session, "the shell to be ready", |text| text.chars().any(|c| !c.is_whitespace()))
        .await;

    // More lines than the screen holds, each one identifiable.
    session.write(b"for i in $(seq 1 40); do echo marker-$i; done\n".to_vec()).expect("live");

    settle(&session, "the last line", |text| text.contains("marker-40")).await;

    let live = session.screen().text();
    assert!(!live.contains("marker-1\n"), "the first line has scrolled away:\n{live}");
    assert!(session.viewport().history > 0, "there is history to read");

    session.scroll(Scroll::Oldest);
    let history = session.screen().text();
    assert!(!session.viewport().is_live(), "the viewport left the live screen");
    assert_ne!(history, live, "and is showing something else");

    // Typing comes back to the present. A keystroke whose echo lands
    // off-screen reads as a terminal that ignored it.
    session
        .send(&tether_core::terminal::Input::key(tether_core::terminal::Key::Enter))
        .expect("live");
    assert!(session.viewport().is_live(), "typing returned to the live screen");

    session.close().await.expect("closes cleanly");
}
