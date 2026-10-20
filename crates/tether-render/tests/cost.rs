//! Manual CPU layout observations; hardware timings never gate CI.
//! Run: cargo test -p tether-render --test cost -- --ignored --nocapture
//! These measure prepare(), not font shaping, GPU execution or presentation.

use std::time::Instant;

use tether_render::{Caret, FontMetrics, Frame, Name, Paint, Palette, Row, Run, RunStyle, prepare};

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
    // Exercise preparation once before collecting approximate CPU timings.
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
}

#[test]
#[ignore = "manual hardware-dependent performance observation"]
fn observe_ordinary_layout_cost() {
    for (columns, rows) in [(80, 24), (120, 40), (200, 60), (400, 100)] {
        run_shape("prose", &prose(columns, rows), 200);
        run_shape("highlighted", &highlighted(columns, rows), 200);
    }
}

#[test]
#[ignore = "manual hardware-dependent performance observation"]
fn observe_per_cell_layout_cost() {
    // Observe scaling with one run per cell, without a timing assertion.
    for (columns, rows) in [(80, 24), (120, 40), (200, 60)] {
        run_shape("worstCase", &worst_case(columns, rows), 20);
    }
}
