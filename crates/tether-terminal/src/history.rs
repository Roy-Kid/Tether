//! Archive rows at the engine's semantic boundary, before the bounded grid
//! evicts them. This adapter delegates VT behavior to the upstream Handler.
use crate::{
    Cell,
    terminal::{Sink, style_of},
};
use alacritty_terminal::vte::ansi::*;
use alacritty_terminal::{
    grid::Dimensions,
    index::{Column, Line},
    term::{Term, TermMode, cell::Flags},
};
use cursor_icon::CursorIcon;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct HistoryRow {
    pub columns: u16,
    pub wrapped: bool,
    pub cells: Vec<Cell>,
}

#[derive(Debug, Clone)]
pub enum HistoryEvent {
    Row(HistoryRow),
    /// An explicit clear-scrollback/reset also erases the disk history.
    Clear,
    /// Replace the live grid's reflowed tail on resize.
    Truncate(usize),
}

#[derive(Default)]
pub(crate) struct Capture {
    pub events: Vec<HistoryEvent>,
    pub main_screen: Vec<HistoryRow>,
    pub main_history: usize,
    pub reflowed: bool,
}

pub(crate) fn row(term: &Term<Sink>, line: i32) -> HistoryRow {
    let grid = term.grid();
    let columns = grid.columns();
    let cells = (0..columns)
        .filter_map(|column| {
            let cell = &grid[Line(line)][Column(column)];
            if cell.flags.contains(Flags::WIDE_CHAR_SPACER)
                && column > 0
                && grid[Line(line)][Column(column - 1)].flags.contains(Flags::WIDE_CHAR)
            {
                return None;
            }
            let spacer =
                cell.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
            let mut text = if spacer {
                " ".to_owned()
            } else {
                if cell.c == '\t' { " ".to_owned() } else { cell.c.to_string() }
            };
            if !spacer && let Some(extra) = cell.zerowidth() {
                text.extend(extra);
            }
            let wide = cell.flags.contains(Flags::WIDE_CHAR)
                && column + 1 < columns
                && grid[Line(line)][Column(column + 1)].flags.contains(Flags::WIDE_CHAR_SPACER);
            Some(Cell { text, width: if wide { 2 } else { 1 }, style: style_of(cell) })
        })
        .collect();
    HistoryRow {
        columns: columns as u16,
        wrapped: grid[Line(line)][Column(columns - 1)].flags.contains(Flags::WRAPLINE),
        cells,
    }
}

pub(crate) fn screen(term: &Term<Sink>) -> Vec<HistoryRow> {
    (0..term.grid().screen_lines()).map(|line| row(term, line as i32)).collect()
}

pub(crate) struct Recording<'a> {
    pub term: &'a mut Term<Sink>,
    pub capture: &'a mut Capture,
    pub limit: usize,
}

impl Recording<'_> {
    fn mutate(&mut self, operation: impl FnOnce(&mut Term<Sink>)) {
        if self.term.mode().contains(TermMode::ALT_SCREEN) {
            operation(self.term);
            return;
        }
        let before = self.term.grid().history_size();
        // One VT operation can scroll at most a screen. Reserve headroom only
        // for that operation; Unlimited never changes the live grid's limit.
        let capacity = before + self.term.grid().screen_lines() + 1;
        self.term.grid_mut().update_history(capacity);
        operation(self.term);
        let after = self.term.grid().history_size();
        for line in -(after.saturating_sub(before) as i32)..0 {
            self.capture.events.push(HistoryEvent::Row(row(self.term, line)));
        }
        self.term.grid_mut().update_history(self.limit);
    }
}

macro_rules! delegate {
    ($($name:ident($($arg:ident: $ty:ty),*);)*) => {$(
        fn $name(&mut self, $($arg: $ty),*) { self.term.$name($($arg),*); }
    )*};
}
macro_rules! capture {
    ($($name:ident($($arg:ident: $ty:ty),*);)*) => {$(
        fn $name(&mut self, $($arg: $ty),*) { self.mutate(|term| term.$name($($arg),*)); }
    )*};
}

impl Handler for Recording<'_> {
    delegate! {
        set_title(a0: Option<String>);
        set_cursor_style(a0: Option<CursorStyle>);
        set_cursor_shape(a0: CursorShape);
        goto(a0: i32, a1: usize);
        goto_line(a0: i32);
        goto_col(a0: usize);
        insert_blank(a0: usize);
        move_up(a0: usize);
        move_down(a0: usize);
        identify_terminal(a0: Option<char>);
        device_status(a0: usize);
        move_forward(a0: usize);
        move_backward(a0: usize);
        move_down_and_cr(a0: usize);
        move_up_and_cr(a0: usize);
        backspace();
        carriage_return();
        bell();
        substitute();
        set_horizontal_tabstop();
        scroll_down(a0: usize);
        insert_blank_lines(a0: usize);
        erase_chars(a0: usize);
        delete_chars(a0: usize);
        move_backward_tabs(a0: u16);
        move_forward_tabs(a0: u16);
        save_cursor_position();
        restore_cursor_position();
        clear_line(a0: LineClearMode);
        clear_tabs(a0: TabulationClearMode);
        set_tabs(a0: u16);
        reverse_index();
        terminal_attribute(a0: Attr);
        set_mode(a0: Mode);
        unset_mode(a0: Mode);
        report_mode(a0: Mode);
        report_private_mode(a0: PrivateMode);
        set_scrolling_region(a0: usize, a1: Option<usize>);
        set_keypad_application_mode();
        unset_keypad_application_mode();
        set_active_charset(a0: CharsetIndex);
        configure_charset(a0: CharsetIndex, a1: StandardCharset);
        set_color(a0: usize, a1: Rgb);
        dynamic_color_sequence(a0: String, a1: usize, a2: &str);
        reset_color(a0: usize);
        clipboard_store(a0: u8, a1: &[u8]);
        clipboard_load(a0: u8, a1: &str);
        decaln();
        push_title();
        pop_title();
        text_area_size_pixels();
        text_area_size_chars();
        set_hyperlink(a0: Option<Hyperlink>);
        set_mouse_cursor_icon(a0: CursorIcon);
        report_keyboard_mode();
        push_keyboard_mode(a0: KeyboardModes);
        pop_keyboard_modes(a0: u16);
        set_keyboard_mode(a0: KeyboardModes, a1: KeyboardModesApplyBehavior);
        set_modify_other_keys(a0: ModifyOtherKeys);
        report_modify_other_keys();
        set_scp(a0: ScpCharPath, a1: ScpUpdateMode);
    }
    capture! {
        put_tab(a0: u16);
        input(a0: char);
        linefeed();
        newline();
        scroll_up(a0: usize);
        delete_lines(a0: usize);
    }
    fn set_private_mode(&mut self, mode: PrivateMode) {
        // Save the primary screen before upstream exchanges its grids.
        // Only a screen-mode switch needs this copy, not ordinary SGR input.
        if matches!(mode, PrivateMode::Named(NamedPrivateMode::SwapScreenAndSetRestoreCursor))
            && !self.term.mode().contains(TermMode::ALT_SCREEN)
        {
            self.capture.main_screen = screen(self.term);
            self.capture.main_history = self.term.grid().history_size();
            self.capture.reflowed = false;
        }
        self.term.set_private_mode(mode);
    }
    fn unset_private_mode(&mut self, mode: PrivateMode) {
        let was_alt = self.term.mode().contains(TermMode::ALT_SCREEN);
        self.term.unset_private_mode(mode);
        if was_alt && !self.term.mode().contains(TermMode::ALT_SCREEN) && self.capture.reflowed {
            self.capture.events.push(HistoryEvent::Truncate(self.capture.main_history));
            let depth = self.term.grid().history_size();
            for line in -(depth as i32)..0 {
                self.capture.events.push(HistoryEvent::Row(row(self.term, line)));
            }
            self.term.grid_mut().update_history(self.limit);
            self.capture.reflowed = false;
        }
    }

    fn clear_screen(&mut self, mode: ClearMode) {
        if matches!(mode, ClearMode::Saved) && !self.term.mode().contains(TermMode::ALT_SCREEN) {
            self.capture.events.push(HistoryEvent::Clear);
        }
        self.mutate(|term| term.clear_screen(mode));
    }
    fn reset_state(&mut self) {
        self.capture.events.push(HistoryEvent::Clear);
        self.capture.main_screen.clear();
        self.term.reset_state();
    }
}

/// Produce only text and SGR from a structured archive. Never replay remote
/// OSC, device queries, input modes, or bytes that can reach a PTY.
pub(crate) fn display_bytes(rows: &[HistoryRow]) -> Vec<u8> {
    use crate::{Color as C, NamedColor as N, Underline};
    use std::fmt::Write;
    fn color(out: &mut String, value: C, foreground: bool) {
        let prefix = if foreground { 38 } else { 48 };
        match value {
            C::Rgb { red, green, blue } => {
                let _ = write!(out, "\x1b[{prefix};2;{red};{green};{blue}m");
            }
            C::Indexed(index) => {
                let _ = write!(out, "\x1b[{prefix};5;{index}m");
            }
            C::Named(named) => {
                let index = match named {
                    N::Black => 0,
                    N::Red => 1,
                    N::Green => 2,
                    N::Yellow => 3,
                    N::Blue => 4,
                    N::Magenta => 5,
                    N::Cyan => 6,
                    N::White => 7,
                    N::BrightBlack => 8,
                    N::BrightRed => 9,
                    N::BrightGreen => 10,
                    N::BrightYellow => 11,
                    N::BrightBlue => 12,
                    N::BrightMagenta => 13,
                    N::BrightCyan => 14,
                    N::BrightWhite => 15,
                    _ => {
                        return;
                    }
                };
                let _ = write!(out, "\x1b[{prefix};5;{index}m");
            }
        }
    }
    let mut out = String::new();
    for row in rows {
        let end = if row.wrapped {
            row.cells.len()
        } else {
            row.cells.iter().rposition(|cell| !cell.is_blank()).map_or(0, |index| index + 1)
        };
        let mut previous = None;
        for cell in &row.cells[..end] {
            if previous != Some(cell.style) {
                let s = cell.style;
                out.push_str("\x1b[0m");
                color(&mut out, s.foreground, true);
                color(&mut out, s.background, false);
                for (enabled, code) in [
                    (s.bold, 1),
                    (s.dim, 2),
                    (s.italic, 3),
                    (s.inverse, 7),
                    (s.hidden, 8),
                    (s.strikethrough, 9),
                ] {
                    if enabled {
                        let _ = write!(out, "\x1b[{code}m");
                    }
                }
                let underline = match s.underline {
                    Underline::None => 0,
                    Underline::Single => 1,
                    Underline::Double => 2,
                    Underline::Curly => 3,
                    Underline::Dotted => 4,
                    Underline::Dashed => 5,
                };
                if underline > 0 {
                    let _ = write!(out, "\x1b[4:{underline}m");
                }
                if let Some(c) = s.underline_color {
                    match c {
                        C::Rgb { red, green, blue } => {
                            let _ = write!(out, "\x1b[58:2::{red}:{green}:{blue}m");
                        }
                        C::Indexed(i) => {
                            let _ = write!(out, "\x1b[58:5:{i}m");
                        }
                        _ => {}
                    }
                }
                previous = Some(s);
            }
            out.extend(cell.text.chars().filter(|c| !c.is_control()));
        }
        if !row.wrapped {
            out.push_str("\x1b[0m\r\n");
        }
    }
    out.push_str("\x1b[0m\r\n── Session restored ──\r\n");
    out.into_bytes()
}
