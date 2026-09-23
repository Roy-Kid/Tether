//! The compatibility corpus: what real programs wrote, and what it must mean.
//!
//! Compatibility is driven by testing against real workloads (spec §12), so
//! these are not hand-written escape sequences. Each `.vt` file is what a
//! program actually wrote to a pty at 80x24, recorded by
//! `scripts/record-corpus.py` and committed — which is what makes this test
//! deterministic and why it needs neither vim nor tmux to run.
//!
//! Phase 2 is done when "recorded streams from §12's workloads produce
//! asserted state" (spec §23). This file is that assertion.

mod support;

use std::fs;
use std::path::PathBuf;

use support::{invariants, mirror::Mirror, snapshot};
use tether_terminal::{Options, ScreenSize, Terminal};

/// The size everything was recorded at. Replaying at another size would be
/// replaying a stream that was written for a screen it never saw.
const COLUMNS: u16 = 80;
const ROWS: u16 = 24;

/// The workloads §12 names, and the program each recording came from.
///
/// The list is here rather than inferred from the directory on purpose: a
/// recording that goes missing must fail the build, not quietly shrink the
/// corpus.
const WORKLOADS: &[(&str, &str)] = &[
    ("shell", "a shell — colour, a wide character, and a prompt redrawn"),
    ("vim", "an editor — the alternate screen, a status line, syntax colour"),
    ("less", "a pager — whole-screen scrolling and a status line rewritten"),
    ("dashboard", "a monitoring TUI — boxes and regions repainted by address"),
    ("finder", "a fuzzy finder — a list redrawn under the prompt, no alt screen"),
    ("git", "a git interface — generated colour and a graph in box characters"),
    ("tmux", "tmux — a terminal inside a terminal, with borders and a status line"),
    ("agent", "a streaming agent interface — a spinner, and lines rewritten"),
];

fn corpus() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/corpus")
}

fn terminal() -> Terminal {
    // The scrollback a recording needs is small, and the default ten thousand
    // lines would measure the allocator rather than the engine.
    Terminal::with_options(ScreenSize::new(COLUMNS, ROWS), Options { scrollback_lines: 500 })
}

fn recording(name: &str) -> Vec<u8> {
    let path = corpus().join(format!("{name}.vt"));
    fs::read(&path).unwrap_or_else(|error| {
        panic!("{}: {error}. Re-record with `python3 scripts/record-corpus.py`", path.display())
    })
}

#[test]
fn every_workload_the_specification_names_has_a_recording() {
    for (name, description) in WORKLOADS {
        let bytes = recording(name);
        assert!(!bytes.is_empty(), "{name}.vt is empty — {description}");
    }
}

/// The assertion Phase 2 is measured by: these bytes, this screen.
///
/// The snapshot carries the grid's text, a marker line keyed to the styles
/// under it, the cursor, and the modes — so a reviewer can see from the diff
/// whether a change to the engine made a real terminal better or worse.
///
/// Regenerate deliberately, and read the diff:
/// `TETHER_BLESS=1 cargo test -p tether-terminal --test corpus`
#[test]
fn recorded_workloads_produce_the_asserted_screen() {
    let blessing = std::env::var_os("TETHER_BLESS").is_some();
    let mut stale = Vec::new();

    for (name, description) in WORKLOADS {
        let bytes = recording(name);
        let mut term = terminal();
        let mut rendered = format!(
            "# {name} — {description}\n#\n# {} bytes at {COLUMNS}x{ROWS}. Regenerate with TETHER_BLESS=1.\n\n",
            bytes.len()
        );

        // Two points, because the end of a full-screen program is often an
        // empty screen: `vim` leaves the alternate screen on the way out, and
        // a snapshot of only the end would assert nothing about the editor.
        let halfway = bytes.len() / 2;
        term.feed(&bytes[..halfway]);
        invariants::check(&mut term, &format!("{name} at {halfway} bytes"));
        rendered.push_str(&snapshot::render(
            &format!("after {halfway} of {} bytes", bytes.len()),
            &term.screen(),
            term.title(),
        ));

        term.feed(&bytes[halfway..]);
        invariants::check(&mut term, &format!("{name} at {} bytes", bytes.len()));
        rendered.push('\n');
        rendered.push_str(&snapshot::render("at the end", &term.screen(), term.title()));

        let path = corpus().join(format!("{name}.snap"));
        let recorded = fs::read_to_string(&path).unwrap_or_default();
        if recorded == rendered {
            continue;
        }
        if blessing {
            fs::write(&path, &rendered).expect("writing a snapshot");
            continue;
        }
        stale.push(format!("{name}: {}", difference(&recorded, &rendered)));
    }

    assert!(
        stale.is_empty(),
        "the screen these recordings produce has changed:\n{}\n\nIf the change is \
         right, regenerate with `TETHER_BLESS=1 cargo test -p tether-terminal --test corpus` \
         and review the diff.",
        stale.join("\n")
    );
}

/// A network delivers whatever sizes it likes, and a recording is the only
/// place we have real streams to cut up. Every escape sequence and every
/// scalar in the corpus gets split somewhere across these chunk sizes.
#[test]
fn a_recording_fed_in_fragments_lands_on_the_same_screen() {
    for (name, _) in WORKLOADS {
        let bytes = recording(name);

        let mut whole = terminal();
        whole.feed(&bytes);
        let expected = whole.screen();
        let replies = whole.take_replies();

        let mut rng = 0x2545_F491_4F6C_DD1Du64 ^ bytes.len() as u64;
        let mut term = terminal();
        let mut collected = Vec::new();
        let mut offset = 0;
        while offset < bytes.len() {
            rng ^= rng >> 12;
            rng ^= rng << 25;
            rng ^= rng >> 27;
            let size = (rng.wrapping_mul(0x2545_F491_4F6C_DD1D) % 97) as usize + 1;
            let end = (offset + size).min(bytes.len());
            term.feed(&bytes[offset..end]);
            collected.extend(term.take_replies());
            invariants::check(&mut term, &format!("{name} fragmented at {offset}"));
            offset = end;
        }

        assert_eq!(term.screen(), expected, "{name}: fragmenting the stream changed the screen");
        assert_eq!(collected, replies, "{name}: fragmenting the stream changed the replies");
    }
}

/// The damage contract, checked against real output.
///
/// A frontend that redraws only what it was told changed must end up with the
/// screen the engine has. A missing span would leave stale text on a real
/// terminal — and a test that only ever reads whole screens would never see
/// it (spec §12).
#[test]
fn damage_alone_is_enough_to_redraw_a_recorded_workload() {
    for (name, _) in WORKLOADS {
        let bytes = recording(name);
        let mut term = terminal();

        // Feeding in chunks is the point: damage is per frame, and one feed
        // of the whole recording would report a single full redraw.
        let mut mirror = Mirror::new(&term.screen());
        for (index, chunk) in bytes.chunks(64).enumerate() {
            term.feed(chunk);
            let changes = term.take_changes();
            let screen = term.screen();
            mirror.apply(&changes, &screen);

            if let Some(disagreement) = mirror.disagreement(&screen) {
                panic!("{name}: damage was not enough at chunk {index}\n{disagreement}");
            }
        }
    }
}

/// The first line that differs, which is what a person needs to see first.
fn difference(recorded: &str, rendered: &str) -> String {
    for (number, (was, now)) in recorded.lines().zip(rendered.lines()).enumerate() {
        if was != now {
            return format!("line {}\n  recorded: {was:?}\n       now: {now:?}", number + 1);
        }
    }
    if recorded.is_empty() {
        return "no snapshot recorded yet".to_string();
    }
    format!("{} lines recorded, {} now", recorded.lines().count(), rendered.lines().count())
}
