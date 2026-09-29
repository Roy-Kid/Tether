//! The whole composition against a real shell on this machine.
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
use tether_core::terminal::{Input, Key, Options, Palette, Position, Rgb, ScreenSize};
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
async fn what_a_local_shell_writes_reaches_the_screen() {
    let session = running("printf 'hello from this machine\\n'")
        .size(ScreenSize::new(80, 24))
        .open()
        .await
        .expect("a local shell");

    let screen =
        settle(&session, "the shell's output", |text| text.contains("hello from this machine"))
            .await;
    assert!(screen.contains("hello from this machine"));
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
async fn the_shell_is_told_how_big_the_screen_is() {
    let session =
        running("stty size").size(ScreenSize::new(120, 40)).open().await.expect("a local shell");

    settle(&session, "stty's answer", |text| text.contains("40 120")).await;
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
async fn closing_ends_the_session() {
    // A shell that would otherwise wait on its terminal for ever, so what is
    // being measured is the close and not the shell losing interest.
    let session = Local::running(Command::new("/bin/sh")).open().await.expect("a local shell");
    session.close_in_place();
    assert_eq!(ending(&session).await, Ending::Closed);
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

/// A shell that reports where it is, and a path it printed, reach the
/// consumer through the session: the two things pointing at output needs.
#[tokio::test]
async fn a_session_knows_where_its_shell_is_and_what_its_output_names() {
    let session = running(r"printf '\033]7;file://here/tmp/runs\007wrote out/plot.png\n'; sleep 5")
        .open()
        .await
        .expect("a local shell");
    settle(&session, "the path", |text| text.contains("out/plot.png")).await;

    assert_eq!(session.working_directory().as_deref(), Some("/tmp/runs"));
    let row = session
        .screen()
        .rows()
        .position(|row| {
            row.iter().map(|cell| cell.text.as_str()).collect::<String>().contains("plot")
        })
        .expect("the row") as u16;
    let link = session.link_at(Position::new(row, 8)).expect("a link");
    assert_eq!(link.text, "out/plot.png");
}

/// Files on this machine are spoken to the way files anywhere are: SFTP, to
/// the `sftp-server` OpenSSH installed. The version exchange is the smallest
/// thing that proves a real server answered on the channel.
#[tokio::test]
async fn a_local_connection_speaks_sftp_to_this_machines_server() {
    let session = running("exit 0").open().await.expect("a local shell");
    let connection = session.connection().expect("a connection");

    let mut channel = match connection.sftp().await {
        Ok(channel) => channel,
        Err(error) => {
            assert!(
                std::env::var_os("TETHER_REQUIRE_SFTP").is_none(),
                "TETHER_REQUIRE_SFTP is set and sftp failed: {error}"
            );
            eprintln!("skipping: {error}");
            return;
        }
    };

    // SSH_FXP_INIT, version 3: length 5, type 1, then the version.
    channel.write(&[0, 0, 0, 5, 1, 0, 0, 0, 3]).await.expect("the init is written");
    let mut reply = Vec::new();
    while reply.len() < 9 {
        reply.extend(channel.read().await.expect("a read").expect("the server answers"));
    }
    // SSH_FXP_VERSION is type 2, and OpenSSH answers with version 3.
    assert_eq!(reply[4], 2, "{reply:?}");
    assert_eq!(&reply[5..9], &[0, 0, 0, 3]);
    channel.close().await;
}

/// A local file session starts at home, as a remote one does: `sshd` starts
/// its `sftp-server` there, and ours would otherwise start wherever this
/// process happens to be — `/`, for an application the Finder launched.
#[tokio::test]
async fn a_local_file_session_starts_at_home() {
    let session = running("exit 0").open().await.expect("a local shell");
    let connection = session.connection().expect("a connection");
    let Ok(mut channel) = connection.sftp().await else { return };

    // SSH_FXP_INIT, then SSH_FXP_REALPATH "." with request id 1.
    channel.write(&[0, 0, 0, 5, 1, 0, 0, 0, 3]).await.expect("init");
    channel.write(&[0, 0, 0, 10, 16, 0, 0, 0, 1, 0, 0, 0, 1, b'.']).await.expect("realpath");
    // The VERSION reply, then the NAME reply: length, type, id, count, and
    // the first name as a length-prefixed string.
    let mut reply = Vec::new();
    let word = |bytes: &[u8], at: usize| {
        u32::from_be_bytes(bytes[at..at + 4].try_into().expect("four bytes")) as usize
    };
    let named = loop {
        if reply.len() >= 4 {
            let version = 4 + word(&reply, 0);
            if reply.len() >= version + 17 {
                let length = word(&reply, version + 13);
                if reply.len() >= version + 17 + length {
                    break String::from_utf8_lossy(&reply[version + 17..version + 17 + length])
                        .into_owned();
                }
            }
        }
        match channel.read().await.expect("a read") {
            Some(bytes) => reply.extend(bytes),
            None => panic!("the server stopped before answering: {reply:?}"),
        }
    };
    let home = std::fs::canonicalize(std::env::var("HOME").expect("HOME")).expect("home");
    assert_eq!(std::path::Path::new(&named), home);
    channel.close().await;
}

/// The caller writes one command line, quoted the way a shell reads it,
/// because that is what the remote arm hands to `sshd`. Two arms that parsed
/// the same string differently would be a seam that only looked like one.
#[tokio::test]
async fn a_command_is_read_by_a_shell() {
    let session = running("exit 0").open().await.expect("a local shell");
    let connection = session.connection().expect("a connection");

    let captured =
        connection.capture("printf '%s' 'one two'", 4096).await.expect("the command should run");

    assert_eq!(captured.text(), "one two");
}

#[tokio::test]
async fn a_command_that_fails_says_why_in_its_own_words() {
    let session = running("exit 0").open().await.expect("a local shell");
    let connection = session.connection().expect("a connection");

    let captured = connection
        .capture("printf nope >&2; exit 2", 4096)
        .await
        .expect("a command that fails still ran");

    assert!(!captured.succeeded());
    assert_eq!(captured.status, Some(2));
    assert_eq!(captured.complaint(), "nope");
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

#[tokio::test]
async fn scrollback_is_kept_for_a_local_shell_too() {
    let session = running("i=0; while [ $i -lt 60 ]; do printf 'line %d\\n' $i; i=$((i+1)); done")
        .size(ScreenSize::new(80, 24))
        .options(Options { scrollback_lines: 1000 })
        .open()
        .await
        .expect("a local shell");

    settle(&session, "the last line", |text| text.contains("line 59")).await;

    let viewport = session.viewport();
    assert!(viewport.history > 0, "nothing was kept above the screen");
}

#[tokio::test]
async fn a_program_that_cannot_start_is_reported_before_a_session_exists() {
    let opened =
        Local::running(Command::new("/nonexistent/tether-should-never-find-this")).open().await;
    assert!(opened.is_err(), "a session was created for a program that cannot run");
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

/// A program asking what the background is gets an answer, over a real PTY.
///
/// The round trip that decides whether a remote program paints itself dark:
/// it writes `OSC 11 ; ?`, and what comes back on its own input is what the
/// consumer said it draws with. Unanswered, a program assumes dark — which
/// is a light window with a black screen in it, and no palette on the
/// drawing side can undo that, because the cells then carry explicit
/// colours.
///
/// `stty min 0 time 10` so the read returns with whatever arrived rather
/// than waiting for a fixed number of bytes; the escape and the bell are
/// stripped so the answer lands on the screen as text rather than as another
/// sequence.
#[tokio::test]
async fn a_program_asking_for_the_background_is_told_what_the_consumer_draws() {
    let session = running(
        r#"sleep 1
stty raw -echo min 0 time 10
printf '\033]11;?\a'
sleep 1
answer=$(dd bs=64 count=1 2>/dev/null | tr -d '\033\007')
printf 'ANSWER[%s]\r\n' "$answer"
sleep 5
"#,
    )
    .size(ScreenSize::new(80, 24))
    .open()
    .await
    .expect("a local shell");

    session.set_palette(Some(light()));

    let screen = settle(&session, "the program's answer", |text| text.contains("ANSWER[")).await;
    assert!(
        screen.contains("rgb:fbfb/fbfb/fdfd"),
        "the far side should have been told the consumer's background; screen:\n{screen}"
    );
}

/// A consumer that says nothing leaves the question unanswered, rather than
/// having a colour invented for it (spec §12).
#[tokio::test]
async fn a_program_asking_a_silent_consumer_hears_nothing() {
    let session = running(
        r#"sleep 1
stty raw -echo min 0 time 10
printf '\033]11;?\a'
sleep 1
answer=$(dd bs=64 count=1 2>/dev/null | tr -d '\033\007')
printf 'ANSWER[%s]\r\n' "$answer"
sleep 5
"#,
    )
    .size(ScreenSize::new(80, 24))
    .open()
    .await
    .expect("a local shell");

    let screen = settle(&session, "the program's answer", |text| text.contains("ANSWER[")).await;
    assert!(screen.contains("ANSWER[]"), "nothing was said, so nothing came back:\n{screen}");
}

/// The palette a frontend would hand down, light.
fn light() -> Palette {
    let grey = Rgb::new(0x80, 0x80, 0x80);
    Palette {
        foreground: Rgb::new(0x1f, 0x21, 0x28),
        background: Rgb::new(0xfb, 0xfb, 0xfd),
        cursor: Rgb::new(0x00, 0x7a, 0xff),
        ansi: [grey; 16],
    }
}
