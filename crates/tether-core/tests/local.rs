//! The whole composition against a real shell on this machine.
//!
//! Unix-only: every case drives `/bin/sh`. Windows gets its own dialect
//! (ConPTY + cmd/pwsh) and its own suite when `tether-local` is ported.
#![cfg(unix)]
//!
//! The SSH end-to-end test is skipped unless a server is configured, which
//! means the composition — a byte stream produced by software we did not
//! write, landing on a screen — is usually proved by nothing. A local shell
//! needs no server, so this runs everywhere, every time, and covers the same
//! path: `TerminalSession` over a `Producer` it did not choose.
//!
//! It is also where the claim in §8 is checked rather than asserted. Every
//! test below drives a session through the same API the SSH tests use; if a
//! local session needed different handling anywhere, this file could not be
//! written without naming the difference.

use std::time::Duration;

use tether_core::local_shell::Command;
use tether_core::terminal::{Input, Key, Options, ScreenSize};
use tether_core::{Ending, Local, TerminalSession};

/// Waits until `predicate` holds, or gives up.
///
/// Time-bounded rather than change-bounded: a shell writes its prompt in one
/// write or five, and asserting on a fixed number of frames would be
/// asserting on how the machine felt that morning.
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
            // The last frame is announced *before* the ending, so a shell
            // that wrote and exited in the same breath satisfies the
            // predicate on a screen `changed()` has already stopped
            // reporting. Checking once more here is the difference between
            // reading that screen and calling it a failure.
            let text = session.screen().text();
            if predicate(&text) {
                return text;
            }
            panic!("the session ended while waiting for {what}; the screen held:\n{text}");
        }
    }
}

/// Waits for the session to stop, and says why it did.
async fn ending(session: &TerminalSession) -> Ending {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while session.ending().is_none() {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() || tokio::time::timeout(remaining, session.changed()).await.is_err()
        {
            break;
        }
    }
    session.ending().expect("the session should have ended")
}

fn running(script: &str) -> Local {
    Local::running(Command::new("/bin/sh").arg("-c").arg(script))
}

#[tokio::test]
async fn paused_output_waits_until_the_session_resumes() {
    let session = Local::running(Command::new("/bin/sh"))
        .size(ScreenSize::new(80, 24))
        .open()
        .await
        .expect("a local shell");
    settle(&session, "a prompt", |text| !text.trim().is_empty()).await;

    session.pause();
    tokio::time::sleep(Duration::from_millis(50)).await;
    session.write(b"printf 'paused-marker\\n'\n".to_vec()).expect("write");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        !session.screen().text().contains("paused-marker"),
        "paused reading must not copy output into the grid"
    );

    session.resume();
    settle(&session, "the marker", |text| text.contains("paused-marker")).await;
}

#[tokio::test]
async fn typing_reaches_the_shell_and_the_echo_reaches_the_screen() {
    // The full round trip through the composition: a `Key`, encoded by the
    // engine against the modes the *shell* set, written by the producer, read
    // back, parsed, and drawn.
    let session = Local::running(Command::new("/bin/sh"))
        .size(ScreenSize::new(80, 24))
        .open()
        .await
        .expect("a local shell");

    for character in "printf 'typ''ed\\n'".chars() {
        session.send(&Input::key(Key::Char(character))).expect("the session accepts input");
    }
    session.send(&Input::key(Key::Enter)).expect("the session accepts input");

    settle(&session, "the shell's reply", |text| text.contains("typed")).await;
}

#[tokio::test]
async fn resizing_reaches_both_halves() {
    let session = Local::running(Command::new("/bin/sh"))
        .size(ScreenSize::new(80, 24))
        .open()
        .await
        .expect("a local shell");

    session.resize(ScreenSize::new(132, 43)).expect("the session resizes");

    // The engine's half is immediate, and must be: a consumer that resized
    // and then laid out its view would otherwise lay it out against a screen
    // that no longer exists.
    assert_eq!(session.size(), ScreenSize::new(132, 43));

    // The shell's half crosses the producer, so it is waited for.
    for character in "stty size; printf 'DO''NE\\n'".chars() {
        session.send(&Input::key(Key::Char(character))).expect("the session accepts input");
    }
    session.send(&Input::key(Key::Enter)).expect("the session accepts input");

    let screen = settle(&session, "stty's answer", |text| text.contains("DONE")).await;
    assert!(screen.contains("43 132"), "the shell was never told; the screen held:\n{screen}");
}

#[tokio::test]
async fn a_shell_that_exits_ends_the_session_with_its_status() {
    let session = running("exit 9").open().await.expect("a local shell");
    assert_eq!(ending(&session).await, Ending::Exited(9));
}

#[tokio::test]
async fn a_local_session_leases_a_connection_of_its_own() {
    // Not a special case for the consumer to remember: a session is asked
    // whether a second command can be run where its shell is, and both kinds
    // answer the same way. Nothing was authenticated here and nothing is
    // held open — but a process can be started on this machine, and saying so
    // is what keeps a feature built on it from being remote-only by accident.
    let session = running("exit 0").open().await.expect("a local shell");
    let connection = session.connection().expect("a local session leases a connection");

    let captured = connection.capture("printf hello", 4096).await.expect("the command should run");

    assert!(captured.succeeded(), "{captured:?}");
    assert_eq!(captured.text(), "hello");
}

/// What a control protocol needs, and the reason it is not a [`Producer`]:
/// no pseudo-terminal, so nothing is echoed back and no line ending is
/// rewritten on the way through.
///
/// [`Producer`]: tether_core::Producer
#[tokio::test]
async fn a_channel_carries_bytes_both_ways_with_no_terminal_in_the_middle() {
    let session = running("exit 0").open().await.expect("a local shell");
    let connection = session.connection().expect("a connection");

    let mut channel = connection.open("cat").await.expect("cat should start");
    channel.write(b"ping\n").await.expect("the channel should accept a write");
    let echoed = channel.read().await.expect("cat should answer").expect("and not be at its end");

    assert_eq!(echoed, b"ping\n");
    channel.close().await;
}

/// A second interactive shell is the same lease, not another login. Locally
/// that is another process; remotely it is another channel. Either way the
/// first session keeps drawing while the second one starts.
#[tokio::test]
async fn a_second_shell_opens_on_the_leased_connection() {
    let first = Local::running(Command::new("/bin/sh")).open().await.expect("first shell");
    let connection = first.connection().expect("a local session leases a connection");
    let second = connection
        .shell("xterm-256color", ScreenSize::new(80, 24), Options::default())
        .await
        .expect("second shell");

    assert!(first.ending().is_none(), "opening another shell must not end the first");
    assert!(second.ending().is_none());

    first.send(&Input::Paste("printf 'one''\\n'\n".into())).expect("first accepts input");
    second.send(&Input::Paste("printf 'two''\\n'\n".into())).expect("second accepts input");

    settle(&first, "the first shell's reply", |text| text.contains("one")).await;
    settle(&second, "the second shell's reply", |text| text.contains("two")).await;
}
