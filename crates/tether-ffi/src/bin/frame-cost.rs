//! What one frame costs on the Rust side of the boundary.
//!
//! Spec §20 names the FFI boundary, screen mutation and damage propagation as
//! performance-sensitive, and says to optimise after profiling. Phase 4
//! chooses a GPU text stack *by measurement* — so there has to be a
//! measurement, taken the same way twice, rather than an impression.
//!
//! This measures the half that is ours: reading the engine's grid into a
//! [`Screen`] and collapsing it into the [`ScreenFrame`] a frontend draws. It
//! does not measure uniffi's lowering into Swift, nor the drawing itself;
//! those are measured from Swift (`RenderCostTests`), and the two halves are
//! added up in `Decisions/0006`.
//!
//! Run it against a release build, which is what ships:
//!
//! ```text
//! cargo run --release -p tether-ffi --bin frame-cost
//! ```

use std::time::Instant;

use tether_core::terminal::{Options, ScreenSize, Terminal};
use tether_ffi::ScreenFrame;

/// Real output, not lorem ipsum: the same recordings the corpus test replays.
/// A screen of plain prose would measure a case a terminal rarely has.
///
/// Each is fed to its halfway point rather than to the end: a full-screen
/// program leaves an empty screen behind when it exits, and an empty screen
/// collapses to one run per row — which would measure the cheapest frame a
/// terminal ever draws and call it typical.
const WORKLOADS: &[(&str, &[u8])] = &[
    ("vim", include_bytes!("../../../tether-terminal/tests/corpus/vim.vt")),
    ("dashboard", include_bytes!("../../../tether-terminal/tests/corpus/dashboard.vt")),
    ("git", include_bytes!("../../../tether-terminal/tests/corpus/git.vt")),
];

/// The sizes worth knowing about: a default window, a large one, and a
/// full-screen 6K display — the worst case a person can actually produce.
const SIZES: &[(u16, u16)] = &[(80, 24), (120, 40), (200, 60), (400, 100)];

const ITERATIONS: usize = 200;

/// Every cell its own colour, which is the most runs a screen can carry: one
/// per cell, and one attributed string each on the drawing side. `btop` and a
/// full-colour image viewer both approach it, so it is a ceiling that people
/// really do reach — not a synthetic worst case invented to look bad.
fn rainbow() -> &'static [u8] {
    static CELLS: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
    CELLS
        .get_or_init(|| {
            let mut bytes = Vec::new();
            for row in 0..200u16 {
                for column in 0..400u16 {
                    let red = (row.wrapping_mul(7) % 256) as u8;
                    let green = (column.wrapping_mul(11) % 256) as u8;
                    let blue = ((row + column) % 256) as u8;
                    bytes.extend_from_slice(format!("\x1b[38;2;{red};{green};{blue}m#").as_bytes());
                }
                bytes.extend_from_slice(b"\r\n");
            }
            bytes
        })
        .as_slice()
}

fn main() {
    println!("frame cost — {ITERATIONS} frames per measurement, release build\n");
    println!(
        "{:<12} {:>9} {:>10} {:>10} {:>9} {:>8}",
        "workload", "size", "screen", "frame", "total", "runs"
    );

    for (name, bytes) in WORKLOADS.iter().copied().chain(std::iter::once(("worst case", rainbow())))
    {
        for (columns, rows) in SIZES {
            let mut term = Terminal::with_options(
                ScreenSize::new(*columns, *rows),
                Options { scrollback_lines: 2000 },
            );
            term.feed(&bytes[..bytes.len() / 2]);
            let _ = term.take_replies();

            let started = Instant::now();
            let mut screens = Vec::with_capacity(ITERATIONS);
            for _ in 0..ITERATIONS {
                screens.push(term.screen());
            }
            let reading = started.elapsed() / ITERATIONS as u32;

            let started = Instant::now();
            let mut frames = Vec::with_capacity(ITERATIONS);
            for screen in &screens {
                frames.push(ScreenFrame::of(screen, term.title().to_string()));
            }
            let collapsing = started.elapsed() / ITERATIONS as u32;

            // How many runs a frame carries is the number that decides the
            // drawing cost on the other side: one attributed string each.
            let runs: usize = frames[0].lines.iter().map(|line| line.runs.len()).sum();

            println!(
                "{name:<12} {:>9} {:>9.0?} {:>9.0?} {:>8.0?} {runs:>8}",
                format!("{columns}x{rows}"),
                reading,
                collapsing,
                reading + collapsing,
            );
        }
    }

    println!(
        "\nscreen = Terminal::screen(), frame = ScreenFrame::of().\n\
         Neither uniffi's lowering nor any drawing is included."
    );
}
