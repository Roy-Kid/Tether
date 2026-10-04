//! What a local shell must actually do.
//!
//! Every test here runs a real process on a real pseudo-terminal. Nothing is
//! mocked, because the parts worth doubting — that the slave is closed so
//! end-of-file arrives, that a resize reaches the child, that a hang-up is
//! felt — are exactly the parts a mock would assert into existence.

use std::time::Duration;

use tether_local::{Command, LocalError, Output, Shell, WindowSize};

/// Reads until the shell is over, returning everything it wrote and the
/// status it ended with.
async fn run(mut shell: Shell) -> (String, Option<u32>) {
    let mut text = Vec::new();
    let mut status = None;
    while let Some(output) = shell.next_output().await {
        match output {
            Output::Bytes(bytes) => text.extend_from_slice(&bytes),
            Output::Exited(code) => status = Some(code),
        }
    }
    (String::from_utf8_lossy(&text).into_owned(), status)
}

/// Reads until `needle` appears, giving up after `within`.
///
/// A shell on a terminal writes when it feels like it — a prompt here, an
/// echo there — so waiting for a specific string is the only way to be sure
/// a step finished before the next one starts.
///
/// Callers must pick a needle the *echo* of their own input cannot contain.
/// A terminal echoes what is typed, so waiting for `ONE` after sending a
/// line containing `ONE` succeeds on the echo, before the shell has run
/// anything — measured, and it made this helper look like it worked.
async fn read_for(shell: &mut Shell, needle: &str, within: Duration) -> Option<String> {
    let mut text = Vec::new();
    let deadline = tokio::time::Instant::now() + within;
    while let Ok(Some(Output::Bytes(bytes))) =
        tokio::time::timeout_at(deadline, shell.next_output()).await
    {
        text.extend_from_slice(&bytes);
        let text = String::from_utf8_lossy(&text);
        if text.contains(needle) {
            return Some(text.into_owned());
        }
    }
    None
}

async fn read_until(shell: &mut Shell, needle: &str) -> String {
    read_for(shell, needle, Duration::from_secs(10))
        .await
        .unwrap_or_else(|| panic!("the shell never wrote {needle:?}"))
}

/// Splits a marker so the terminal's echo of the command cannot contain it.
///
/// `printf 'O''NE\n'` is one word to the shell and two to whoever reads the
/// echo, so the string only ever appears in the output.
fn echo_command(marker: &str) -> String {
    let (head, tail) = marker.split_at(1);
    format!("printf '{head}''{tail}\\n'\n")
}

/// Waits until the shell is actually reading its terminal.
///
/// A shell resets its terminal when it starts, and that reset discards
/// whatever is already sitting in the input queue. A test that types the
/// instant `open` returns is therefore racing the shell's own setup: usually
/// it wins, and under load it types into a buffer about to be thrown away —
/// measured, as an intermittent failure that looked like a resize going
/// missing. Asking until an answer comes back is the only reliable way to
/// know somebody is listening.
async fn wait_until_ready(shell: &mut Shell) {
    for attempt in 0..20 {
        let marker = format!("READY{attempt}");
        shell.write(echo_command(&marker)).await.expect("the shell accepts input");
        if read_for(shell, &marker, Duration::from_millis(500)).await.is_some() {
            return;
        }
    }
    panic!("the shell never started reading its terminal");
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[tokio::test]
async fn shell_pid_tracks_its_directory_without_osc_sequences() {
    let start = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    let mut shell =
        Shell::open(Command::new("/bin/sh").arg("-i").directory(&start), WindowSize::default())
            .unwrap();
    wait_until_ready(&mut shell).await;
    let pid = shell.process_id().expect("the spawned shell has a PID");
    assert!(pid > 1);
    assert_eq!(shell.current_directory().as_deref(), start.to_str());
    shell.write("cd /; printf 'DI''RECTORY-CHANGED\\n'\n").await.unwrap();
    read_until(&mut shell, "DIRECTORY-CHANGED").await;
    assert_eq!(shell.process_id(), Some(pid));
    assert_eq!(shell.current_directory().as_deref(), Some("/"));
    shell.close();
}

fn shell_running(script: &str) -> Command {
    Command::new("/bin/sh").arg("-c").arg(script)
}

#[tokio::test]
async fn a_shell_writes_what_it_was_told_to() {
    let shell = Shell::open(shell_running("printf 'tethered\\n'"), WindowSize::default())
        .expect("a pseudo-terminal");
    let (text, _) = run(shell).await;
    assert!(text.contains("tethered"), "got {text:?}");
}

#[tokio::test]
async fn the_last_line_survives_the_exit() {
    // The ordering this asserts is the one that is easy to get wrong: a
    // producer that reported the status the moment the child was reaped
    // would let a consumer stop reading before the final write arrived.
    let shell = Shell::open(shell_running("printf 'last\\n'; exit 7"), WindowSize::default())
        .expect("a pseudo-terminal");

    let mut seen_bytes = false;
    let mut status_arrived_after_output = false;
    let mut shell = shell;
    while let Some(output) = shell.next_output().await {
        match output {
            Output::Bytes(bytes) => {
                if String::from_utf8_lossy(&bytes).contains("last") {
                    seen_bytes = true;
                }
            }
            Output::Exited(code) => {
                assert_eq!(code, 7);
                status_arrived_after_output = seen_bytes;
            }
        }
    }
    assert!(seen_bytes, "the shell's last line never arrived");
    assert!(status_arrived_after_output, "the status was reported before the output");
}

#[tokio::test]
async fn the_stream_ends_when_the_shell_does() {
    // Proves the slave end was dropped after the fork. While this process
    // holds one, the kernel sees a reader and the master never reports
    // end-of-file — the session would wait for ever on a shell that is gone.
    let shell =
        Shell::open(shell_running("exit 0"), WindowSize::default()).expect("a pseudo-terminal");
    let ended = tokio::time::timeout(Duration::from_secs(10), run(shell)).await;
    assert!(ended.is_ok(), "the output stream never ended");
}

#[tokio::test]
async fn a_status_is_reported_even_with_no_output() {
    let shell =
        Shell::open(shell_running("exit 3"), WindowSize::default()).expect("a pseudo-terminal");
    let (_, status) = run(shell).await;
    assert_eq!(status, Some(3));
}

#[tokio::test]
async fn the_shell_starts_at_the_size_it_was_given() {
    let shell = Shell::open(shell_running("stty size"), WindowSize::new(120, 40))
        .expect("a pseudo-terminal");
    let (text, _) = run(shell).await;
    assert!(text.contains("40 120"), "stty reported {text:?}");
}

/// Asks the shell what size it believes its terminal is.
async fn ask_size(shell: &mut Shell, marker: &str) -> String {
    shell
        .write(format!("stty size; {}", echo_command(marker)))
        .await
        .expect("the shell accepts input");
    read_until(shell, marker).await
}

#[tokio::test]
async fn resizing_reaches_the_child() {
    let mut shell =
        Shell::open(Command::new("/bin/sh"), WindowSize::new(80, 24)).expect("a pseudo-terminal");
    wait_until_ready(&mut shell).await;

    let before = ask_size(&mut shell, "ONE").await;
    assert!(before.contains("24 80"), "before the resize, stty reported {before:?}");

    shell.resize(WindowSize::new(132, 43)).expect("the terminal resizes");
    // Our own half is immediate and exact: this is what the kernel was asked
    // for, and nothing has to be waited on to know it.
    assert_eq!(shell.size(), WindowSize::new(132, 43));

    // The child's half is not. A resize reaches it as `SIGWINCH`, and it is
    // observed when the child next looks — so asking once and demanding the
    // new answer is asserting on how quickly a process was scheduled.
    // Asking until the deadline still fails loudly for a resize that never
    // happened, which is the thing worth catching.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let mut last = String::new();
    let mut attempt = 0;
    while tokio::time::Instant::now() < deadline {
        attempt += 1;
        last = ask_size(&mut shell, &format!("SIZE{attempt}")).await;
        if last.contains("43 132") {
            return;
        }
    }
    panic!("the child was never told the new size; it last reported {last:?}");
}

/// Asks the shell its size until it gives the expected answer.
///
/// A resize reaches a child as `SIGWINCH`, so "now" is not a thing that can
/// be asserted — but "ever" is, and without the size being held the child
/// never converges at all: it reports the old size for the life of the
/// terminal, however long it is asked.
async fn settles_at(shell: &mut Shell, expected: &str, label: &str) -> Option<String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut round = 0;
    let mut last = String::new();
    while tokio::time::Instant::now() < deadline {
        round += 1;
        last = ask_size(shell, &format!("{label}{round}")).await;
        if last.contains(expected) {
            return None;
        }
    }
    Some(last)
}

#[tokio::test]
async fn a_resize_is_never_quietly_dropped() {
    // A shell writes its own cached size back over ours while it is starting,
    // so a resize is applied — the kernel confirms it — and then undone a few
    // milliseconds later. Measured at about one resize in ten, and permanent:
    // the terminal stays 80x24 for the rest of its life, with nothing in any
    // log to say why.
    //
    // It is not a corner case. A tab is opened and *then* laid out, which is
    // a resize arriving a few milliseconds after the shell started — exactly
    // the window. The symptom is a terminal the wrong size inside a pane that
    // is the right one.
    //
    // Repeated, because once is a test that passes nine times in ten.
    for attempt in 0..20 {
        let mut shell = Shell::open(Command::new("/bin/sh"), WindowSize::new(80, 24))
            .expect("a pseudo-terminal");
        wait_until_ready(&mut shell).await;

        shell.resize(WindowSize::new(132, 43)).expect("the terminal resizes");

        if let Some(last) = settles_at(&mut shell, "43 132", &format!("A{attempt}R")).await {
            panic!("attempt {attempt}: the resize was undone; stty reported {last:?}");
        }
    }
}

#[tokio::test]
async fn a_size_that_settled_is_not_taken_back() {
    // The other half of the same rule: holding the size must not mean holding
    // the *first* size. A later resize has to win, or a window could be
    // dragged and spring back.
    let mut shell =
        Shell::open(Command::new("/bin/sh"), WindowSize::new(80, 24)).expect("a pseudo-terminal");
    wait_until_ready(&mut shell).await;

    shell.resize(WindowSize::new(132, 43)).expect("the terminal resizes");
    assert!(settles_at(&mut shell, "43 132", "FIRST").await.is_none());

    shell.resize(WindowSize::new(100, 30)).expect("the terminal resizes again");
    if let Some(last) = settles_at(&mut shell, "30 100", "SECOND").await {
        panic!("the second resize was reverted; stty reported {last:?}");
    }
}

#[tokio::test]
async fn input_reaches_the_shell() {
    let mut shell =
        Shell::open(Command::new("/bin/sh"), WindowSize::default()).expect("a pseudo-terminal");
    wait_until_ready(&mut shell).await;

    shell.write(echo_command("round-trip")).await.expect("the shell accepts input");
    let text = read_until(&mut shell, "round-trip").await;
    assert!(text.contains("round-trip"), "got {text:?}");
}

#[tokio::test]
async fn term_describes_what_the_consumer_can_draw() {
    // Set rather than inherited: `cargo test` runs with whatever `TERM` the
    // calling terminal had, and a shell that believed that would emit
    // sequences this project never agreed to render.
    let command = shell_running("printf '%s\\n' \"$TERM\"").term("xterm-256color");
    let shell = Shell::open(command, WindowSize::default()).expect("a pseudo-terminal");
    let (text, _) = run(shell).await;
    assert!(text.contains("xterm-256color"), "got {text:?}");
}

#[tokio::test]
async fn a_working_directory_is_honoured() {
    let shell = Shell::open(shell_running("pwd").directory("/"), WindowSize::default())
        .expect("a pseudo-terminal");
    let (text, _) = run(shell).await;
    assert!(text.lines().any(|line| line.trim() == "/"), "got {text:?}");
}

#[tokio::test]
async fn a_program_that_does_not_exist_says_so() {
    let error = Shell::open(
        Command::new("/nonexistent/tether-should-never-find-this"),
        WindowSize::default(),
    )
    .expect_err("there is no such program");

    match error {
        LocalError::NotStarted { program, .. } => {
            assert!(program.contains("tether-should-never-find-this"));
        }
        other => panic!("expected NotStarted, got {other:?}"),
    }
}

#[tokio::test]
async fn closing_hangs_the_shell_up() {
    // A shell waiting on its terminal for ever is the case that matters: a
    // tab closed on a running program must not leave the program behind.
    let marker = std::env::temp_dir().join(format!("tether-hup-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);

    let script = format!(
        "trap 'printf hung-up > {} ; exit 0' HUP; printf 'inst''alled\n'; \
         while :; do read line || true; done",
        marker.display()
    );
    let mut shell =
        Shell::open(shell_running(&script), WindowSize::default()).expect("a pseudo-terminal");

    // Wait until the trap is installed, rather than racing it: a hang-up
    // delivered before `trap` has run is a signal with no handler, and the
    // marker file would never appear for a reason that has nothing to do with
    // whether closing works.
    assert!(
        read_for(&mut shell, "installed", Duration::from_secs(10)).await.is_some(),
        "the shell never installed its trap"
    );

    shell.close();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while tokio::time::Instant::now() < deadline && !marker.exists() {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let hung_up = marker.exists();
    let _ = std::fs::remove_file(&marker);
    assert!(hung_up, "the shell was never hung up");
}

#[tokio::test]
async fn dropping_the_handle_hangs_the_shell_up_too() {
    // `close` is the polite path; a dropped handle must not be the impolite
    // one that leaves a process running with nothing attached to it.
    let marker = std::env::temp_dir().join(format!("tether-drop-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);

    let script = format!(
        "trap 'printf dropped > {} ; exit 0' HUP; printf 'inst''alled\n'; \
         while :; do read line || true; done",
        marker.display()
    );
    {
        let mut shell =
            Shell::open(shell_running(&script), WindowSize::default()).expect("a pseudo-terminal");
        assert!(
            read_for(&mut shell, "installed", Duration::from_secs(10)).await.is_some(),
            "the shell never installed its trap"
        );
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while tokio::time::Instant::now() < deadline && !marker.exists() {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let hung_up = marker.exists();
    let _ = std::fs::remove_file(&marker);
    assert!(hung_up, "a dropped shell was left running");
}

#[tokio::test]
async fn a_large_paste_does_not_deadlock() {
    // The write path blocks inside the kernel once a pseudo-terminal's input
    // buffer is full — about a kilobyte. Doing it on the caller's thread
    // would stall the runtime on a person pressing paste.
    let mut shell =
        Shell::open(shell_running("cat > /dev/null; printf 'swallowed\\n'"), WindowSize::default())
            .expect("a pseudo-terminal");

    let paste = "x".repeat(64 * 1024);
    let written = tokio::time::timeout(Duration::from_secs(10), shell.write(paste)).await;
    assert!(written.is_ok(), "a large write never finished");
    assert!(written.unwrap().is_ok(), "a large write failed");
}
