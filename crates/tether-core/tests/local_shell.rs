//! The local shell, through the session loop — the path a window uses.
//!
//! A shell on its own is not enough: it asks `ESC[6n` (where is the cursor?)
//! and waits for the answer. `TerminalSession` is what writes that answer
//! back, so this is the test that matters. A shell that opened and printed
//! nothing because nobody answered it is exactly the bug this guards.
//!
//! Every platform, because Windows is where ConPTY and the DSR question
//! actually bit.

use tether_core::local_shell::Command;
use tether_core::terminal::{Options, ScreenSize};
use tether_core::Local;

#[tokio::test]
async fn a_local_shell_runs_and_is_answered() {
    let local = Local::running(Command::through_shell("echo tether-up"))
        .size(ScreenSize::new(80, 24))
        .options(Options { scrollback_lines: 100 });
    let session = local.open().await.expect("the session should open");

    // The engine answers DSR itself and the loop writes it back, so a
    // program that asked can continue. `echo` then prints and the screen
    // carries it.
    let mut seen = String::new();
    for _ in 0..50 {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        let screen = session.screen();
        for row in screen.rows() {
            for cell in row {
                seen.push_str(&cell.text);
            }
        }
        if seen.contains("tether-up") {
            drop(session);
            return;
        }
    }
    drop(session);
    panic!("the session never showed tether-up; got {seen:?}");
}
