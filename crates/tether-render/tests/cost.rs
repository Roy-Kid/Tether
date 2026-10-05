//! The measurement is a test, not a memory (Decisions/0006, 0016).
//!
//! Three shapes, four sizes, and rate ceilings generous enough that a slower
//! CI machine does not flake the test into deletion. What these catch is an
//! order of magnitude — the size of regression that makes a terminal
//! unusable — not a few percent.

use std::time::Instant;

use tether_render::{Caret, FontMetrics, Frame, Name, Paint, Palette, Row, Run, RunStyle, prepare};

/// Half a cell is the point at which the cursor visibly straddles two
/// characters; the drawing ceiling is orders of magnitude coarser than that.
const FRAME_BUDGET: f32 = 60.0;
const PER_RUN_BUDGET_MICROS: f32 = 100.0;

fn metrics() -> FontMetrics {
    FontMetrics::from_advances(13.0, 8.0, 16.0, 16.0)
}

fn style(index: u8) -> RunStyle {
    RunStyle {
        foreground: Paint::Indexed(index),
        background: if index.is_multiple_of(5) {
            Paint::Named(Name::Background)
        } else {
            Paint::Indexed(16 + (index % 36))
        },
        ..RunStyle::default()
    }
}

/// One run per row.
fn prose(columns: u32, rows: u32) -> Frame {
    let text: String =
        "lorem ipsum dolor sit amet ".repeat(20).chars().take(columns as usize).collect();
    Frame {
        columns,
        rows,
        cursor_row: rows / 2,
        cursor_column: columns / 2,
        cursor_shape: Caret::Block,
        cursor_visible: true,
        alternate_screen: true,
        viewport_offset: 0,
        history_lines: 0,
        title: String::new(),
        lines: (0..rows)
            .map(|_| Row {
                runs: vec![Run { text: text.clone(), columns, style: RunStyle::default() }],
            })
            .collect(),
    }
}

/// Six runs per row — a syntax-highlighted editor.
fn highlighted(columns: u32, rows: u32) -> Frame {
    let per = (columns / 6).max(1);
    Frame {
        columns,
        rows,
        cursor_row: rows / 2,
        cursor_column: columns / 2,
        cursor_shape: Caret::Beam,
        cursor_visible: true,
        alternate_screen: true,
        viewport_offset: 0,
        history_lines: 0,
        title: String::new(),
        lines: (0..rows)
            .map(|row| Row {
                runs: (0..6)
                    .map(|i| Run {
                        text: "x".repeat(per as usize),
                        columns: per,
                        style: style((row * 6 + i) as u8),
                    })
                    .collect(),
            })
            .collect(),
    }
}

/// Every cell its own colour — `btop`, an image viewer, a full-colour TUI.
/// This is the shape 0006 recorded as tens of frames behind on CoreGraphics.
fn worst_case(columns: u32, rows: u32) -> Frame {
    Frame {
        columns,
        rows,
        cursor_row: 0,
        cursor_column: 0,
        cursor_shape: Caret::Hidden,
        cursor_visible: false,
        alternate_screen: true,
        viewport_offset: 0,
        history_lines: 0,
        title: String::new(),
        lines: (0..rows)
            .map(|row| Row {
                runs: (0..columns)
                    .map(|col| Run {
                        text: "█".to_string(),
                        columns: 1,
                        style: style(((row * columns + col) % 256) as u8),
                    })
                    .collect(),
            })
            .collect(),
    }
}

fn run_shape(name: &str, frame: &Frame, iterations: u32) {
    let metrics = metrics();
    let palette = Palette::dark();
    // Warm the caches the way a session does: the first frame loads fonts.
    prepare(frame, &metrics, &palette);

    let started = Instant::now();
    for _ in 0..iterations {
        let list = prepare(frame, &metrics, &palette);
        assert!(!list.is_empty(), "{name} produced nothing to draw");
    }
    let per_frame_ms = started.elapsed().as_secs_f32() * 1000.0 / iterations as f32;
    let runs: usize = frame.lines.iter().map(|row| row.runs.len()).sum();
    let per_run_us = if runs == 0 {
        0.0
    } else {
        started.elapsed().as_secs_f32() * 1_000_000.0 / (iterations as f32 * runs as f32)
    };

    println!(
        "{name} {:>3}x{:<3}  {:6.2}ms/frame  {:6.2}µs/run  ({runs} runs)",
        frame.columns, frame.rows, per_frame_ms, per_run_us
    );

    assert!(
        per_frame_ms < FRAME_BUDGET,
        "{name} at {}x{} took {per_frame_ms}ms per frame (budget {FRAME_BUDGET}ms)",
        frame.columns,
        frame.rows
    );
    // A rate, not the known-bad absolute from 0006's CoreGraphics numbers.
    assert!(
        per_run_us < PER_RUN_BUDGET_MICROS,
        "{name} at {}x{} cost {per_run_us}µs per run (budget {PER_RUN_BUDGET_MICROS}µs)",
        frame.columns,
        frame.rows
    );
}

#[test]
fn ordinary_frames_stay_inside_a_frame() {
    for (columns, rows) in [(80, 24), (120, 40), (200, 60), (400, 100)] {
        run_shape("prose", &prose(columns, rows), 200);
        run_shape("highlighted", &highlighted(columns, rows), 200);
    }
}

#[test]
fn worst_case_is_a_rate_not_an_absolute() {
    // The smallest four sizes keep this test under a second while still
    // exercising one-run-per-cell. 0006's 893ms absolute is not asserted.
    for (columns, rows) in [(80, 24), (120, 40), (200, 60)] {
        run_shape("worstCase", &worst_case(columns, rows), 20);
    }
}
