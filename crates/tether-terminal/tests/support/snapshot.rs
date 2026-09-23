//! Screen state as something a person can read in a diff.
//!
//! A snapshot of a recorded workload is only useful if a reviewer can tell,
//! from the diff alone, whether a change made the terminal better or worse.
//! So the text of the grid is printed as text — and the styling under it as a
//! second line of markers keyed to a legend, because a regression that turns
//! every diff line white is invisible in a plain text dump.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use tether_terminal::{Cell, Color, Modes, Screen, Style};

/// One section of a snapshot file: a heading, the state, and the grid.
pub fn render(heading: &str, screen: &Screen, title: &str) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "── {heading} ──");
    let _ = writeln!(
        out,
        "{}x{} · cursor ({},{}) {:?}{} · {}",
        screen.size.columns,
        screen.size.rows,
        screen.cursor.position.row,
        screen.cursor.position.column,
        screen.cursor.shape,
        if screen.cursor.visible { "" } else { " (hidden)" },
        modes(screen.modes),
    );
    let _ = writeln!(
        out,
        "viewport offset {} of {} history · title {title:?}",
        screen.viewport.offset, screen.viewport.history
    );

    let mut legend: Vec<Style> = Vec::new();
    let mut grid = String::new();
    for (index, row) in screen.rows().enumerate() {
        let _ = writeln!(grid, "{index:>2} │{}", text(row));
        if let Some(marks) = markers(row, &mut legend) {
            let _ = writeln!(grid, "   │{marks}");
        }
    }

    out.push_str(&grid);
    for (index, style) in legend.iter().enumerate() {
        let _ = writeln!(out, "    {} = {}", marker(index), describe(style));
    }
    out
}

fn text(row: &[Cell]) -> String {
    row.iter().map(|cell| cell.text.as_str()).collect::<String>().trim_end().to_string()
}

/// One marker per column, so the markers line up under the text they style.
/// `None` for a row drawn entirely in the default style — most rows, most of
/// the time, and a line of eighty dots under each of them would bury the ones
/// that carry something.
fn markers(row: &[Cell], legend: &mut Vec<Style>) -> Option<String> {
    if row.iter().all(|cell| cell.style == Style::default()) {
        return None;
    }
    let mut line = String::new();
    for cell in row {
        let mark = if cell.style == Style::default() {
            '·'
        } else {
            let index = legend.iter().position(|known| *known == cell.style).unwrap_or_else(|| {
                legend.push(cell.style);
                legend.len() - 1
            });
            marker(index)
        };
        for _ in 0..cell.width.max(1) {
            line.push(mark);
        }
    }
    Some(line.trim_end_matches('\u{b7}').to_string())
}

fn marker(index: usize) -> char {
    // 26 letters, then digits. A grid needing more than 36 distinct styles in
    // one screen is telling the reader something in itself.
    const MARKERS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    *MARKERS.get(index).unwrap_or(&b'?') as char
}

/// Only what differs from the default — a full struct dump per style would
/// bury the one field that changed.
fn describe(style: &Style) -> String {
    let default = Style::default();
    let mut parts = Vec::new();

    if style.foreground != default.foreground {
        parts.push(format!("fg {}", colour(style.foreground)));
    }
    if style.background != default.background {
        parts.push(format!("bg {}", colour(style.background)));
    }
    if style.underline != default.underline {
        parts.push(format!("underline {:?}", style.underline));
    }
    if let Some(colour_of) = style.underline_color {
        parts.push(format!("underline colour {}", colour(colour_of)));
    }
    for (set, name) in [
        (style.bold, "bold"),
        (style.dim, "dim"),
        (style.italic, "italic"),
        (style.strikethrough, "strikethrough"),
        (style.inverse, "inverse"),
        (style.hidden, "hidden"),
    ] {
        if set {
            parts.push(name.to_string());
        }
    }
    parts.join(" ")
}

fn colour(colour: Color) -> String {
    match colour {
        Color::Named(named) => format!("{named:?}"),
        Color::Indexed(index) => format!("#{index}"),
        Color::Rgb { red, green, blue } => format!("rgb({red},{green},{blue})"),
    }
}

fn modes(modes: Modes) -> String {
    let flags = BTreeMap::from([
        ("alt", modes.alternate_screen),
        ("appkeys", modes.application_cursor_keys),
        ("bracketed", modes.bracketed_paste),
        ("mouse", modes.mouse_reporting),
        ("wrap", modes.line_wrap),
    ]);
    flags
        .iter()
        .map(|(name, on)| format!("{name} {}", if *on { "on" } else { "off" }))
        .collect::<Vec<_>>()
        .join(" · ")
}
