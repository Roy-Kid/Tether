//! The engine: bytes in, screen state and damage out.

use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::Processor;

use crate::damage::{Changes, RowSpan, ScreenDamage};
use crate::screen::{Cell, Cursor, CursorShape, Modes, Screen};
use crate::size::{Position, ScreenSize};
use crate::style::{Color, NamedColor, Style, Underline};

/// Things the engine wants to tell someone, collected until asked for.
#[derive(Debug, Default)]
struct Collected {
    title: Option<String>,
    bell: bool,
    /// Replies the terminal owes the far side: cursor-position reports, device
    /// attributes, colour queries. A consumer that dropped these would hang
    /// any program that waits for an answer.
    replies: Vec<u8>,
}

/// Bridges the engine's event callback onto [`Collected`].
///
/// `Arc<Mutex<_>>` because the engine hands events to `&self` while we hold
/// `&mut Term`, and because a `Terminal` should be movable between threads.
#[derive(Clone, Default)]
struct Sink(Arc<Mutex<Collected>>);

impl EventListener for Sink {
    fn send_event(&self, event: Event) {
        let mut collected = self.0.lock().expect("terminal event sink poisoned");
        match event {
            Event::Title(title) => collected.title = Some(title),
            Event::ResetTitle => collected.title = Some(String::new()),
            Event::Bell => collected.bell = true,
            Event::PtyWrite(text) => collected.replies.extend_from_slice(text.as_bytes()),
            // Clipboard, colour and size queries all answer by writing back;
            // the ones that need state we do not have are answered by the
            // consumer, not invented here.
            Event::ColorRequest(_, _)
            | Event::ClipboardLoad(_, _)
            | Event::ClipboardStore(_, _)
            | Event::TextAreaSizeRequest(_)
            | Event::CursorBlinkingChange
            | Event::MouseCursorDirty
            | Event::Wakeup
            | Event::Exit
            | Event::ChildExit(_) => {}
        }
    }
}

/// Alacritty needs pixel dimensions for programs that ask; we have none, and
/// reporting a guess would be worse than reporting nothing.
struct Dims {
    size: ScreenSize,
}

impl Dimensions for Dims {
    fn total_lines(&self) -> usize {
        self.size.rows as usize
    }

    fn screen_lines(&self) -> usize {
        self.size.rows as usize
    }

    fn columns(&self) -> usize {
        self.size.columns as usize
    }
}

/// A headless terminal.
///
/// Feed it the bytes a remote shell produced; ask it what the screen looks
/// like and what changed. It reaches no network and draws nothing.
pub struct Terminal {
    inner: Term<Sink>,
    parser: Processor,
    sink: Sink,
    size: ScreenSize,
    /// Previous values, so a change can be reported as a change rather than
    /// re-sent every frame.
    last_cursor: Option<Cursor>,
    last_modes: Option<Modes>,
    title: String,
    pending_full_damage: bool,
    /// Whether anything has reached the engine since the last
    /// [`take_changes`](Terminal::take_changes).
    ///
    /// The engine marks the cursor's old and new cells damaged on every
    /// `damage()` call, so asking it twice in a row reports a change that did
    /// not happen. Nothing can have changed if no bytes arrived and no resize
    /// occurred, so that is what we check, rather than trying to tell a
    /// spurious cursor span from a real one.
    dirty: bool,
}

impl Terminal {
    pub fn new(size: ScreenSize) -> Self {
        let sink = Sink::default();
        let config = Config { scrolling_history: 10_000, ..Config::default() };
        let inner = Term::new(config, &Dims { size }, sink.clone());

        Self {
            inner,
            parser: Processor::new(),
            sink,
            size,
            last_cursor: None,
            last_modes: None,
            title: String::new(),
            pending_full_damage: false,
            // A terminal nobody has drawn yet needs a first full paint.
            dirty: true,
        }
    }

    pub fn size(&self) -> ScreenSize {
        self.size
    }

    pub fn title(&self) -> &str {
        &self.title
    }

    /// Feeds bytes from the far side.
    ///
    /// Byte-oriented, and safe to call with a stream split anywhere: an escape
    /// sequence or a UTF-8 scalar cut across two calls is resumed, not
    /// dropped. A network delivers whatever sizes it likes, so this is not a
    /// nicety.
    pub fn feed(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.dirty = true;
        self.parser.advance(&mut self.inner, bytes);
    }

    /// Changes the screen size.
    ///
    /// Always reported as full damage: reflow can move every line.
    pub fn resize(&mut self, size: ScreenSize) {
        self.size = size;
        self.inner.resize(Dims { size });
        self.pending_full_damage = true;
        self.dirty = true;
    }

    /// Takes the replies the terminal owes the far side, if any.
    ///
    /// These must be written back over the same channel the bytes came from.
    /// A program that asked "where is the cursor?" is waiting.
    pub fn take_replies(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.sink.0.lock().expect("sink poisoned").replies)
    }

    /// What changed since this was last called, and clears it.
    pub fn take_changes(&mut self) -> Changes {
        let screen = self.take_screen_damage();

        let cursor = self.read_cursor();
        let cursor_changed = self.last_cursor != Some(cursor);
        self.last_cursor = Some(cursor);

        let modes = self.read_modes();
        let modes_changed = self.last_modes != Some(modes);
        self.last_modes = Some(modes);

        let mut collected = self.sink.0.lock().expect("sink poisoned");
        let title = collected.title.take();
        if let Some(title) = &title {
            self.title = title.clone();
        }
        let bell = std::mem::replace(&mut collected.bell, false);

        Changes {
            screen,
            cursor: cursor_changed.then_some(cursor),
            title,
            modes: modes_changed.then_some(modes),
            // Scrollback accounting is not wired up yet; reporting a guess
            // would be worse than reporting nothing, and no consumer of this
            // crate reads it today.
            scrolled_lines: 0,
            bell,
        }
    }

    /// A snapshot of the visible screen.
    pub fn screen(&self) -> Screen {
        let grid = self.inner.grid();
        let mut rows = Vec::with_capacity(self.size.rows as usize);

        for line in 0..self.size.rows as i32 {
            let mut cells = Vec::with_capacity(self.size.columns as usize);
            for column in 0..self.size.columns as usize {
                let cell = &grid[Line(line)][Column(column)];

                // The engine marks the right half of a wide character with a
                // spacer. That is its bookkeeping, not a cell a consumer
                // should have to skip.
                if cell.flags.contains(Flags::WIDE_CHAR_SPACER)
                    || cell.flags.contains(Flags::LEADING_WIDE_CHAR_SPACER)
                {
                    continue;
                }

                let mut text = String::from(cell.c);
                if let Some(zerowidth) = cell.zerowidth() {
                    text.extend(zerowidth);
                }

                cells.push(Cell {
                    text,
                    width: if cell.flags.contains(Flags::WIDE_CHAR) { 2 } else { 1 },
                    style: style_of(cell),
                });
            }
            rows.push(cells);
        }

        Screen::new(self.size, self.read_cursor(), self.read_modes(), rows)
    }

    fn read_cursor(&self) -> Cursor {
        let point = self.inner.grid().cursor.point;
        let mode = self.inner.mode();
        let visible = mode.contains(TermMode::SHOW_CURSOR);

        Cursor {
            position: Position::new(
                point.line.0.max(0) as u16,
                point.column.0.min(u16::MAX as usize) as u16,
            ),
            shape: if visible {
                shape_of(self.inner.cursor_style().shape)
            } else {
                CursorShape::Hidden
            },
            visible,
        }
    }

    fn read_modes(&self) -> Modes {
        let mode = self.inner.mode();
        Modes {
            alternate_screen: mode.contains(TermMode::ALT_SCREEN),
            bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE),
            application_cursor_keys: mode.contains(TermMode::APP_CURSOR),
            mouse_reporting: mode.intersects(TermMode::MOUSE_MODE),
            line_wrap: mode.contains(TermMode::LINE_WRAP),
        }
    }

    fn take_screen_damage(&mut self) -> ScreenDamage {
        let forced_full = std::mem::replace(&mut self.pending_full_damage, false);
        if !std::mem::replace(&mut self.dirty, false) && !forced_full {
            return ScreenDamage::None;
        }

        let damage = match self.inner.damage() {
            TermDamage::Full => ScreenDamage::Full,
            TermDamage::Partial(lines) => {
                let spans: Vec<RowSpan> = lines
                    .map(|line| RowSpan {
                        row: line.line.min(u16::MAX as usize) as u16,
                        first_column: line.left.min(u16::MAX as usize) as u16,
                        last_column: line.right.min(u16::MAX as usize) as u16,
                    })
                    .collect();
                if spans.is_empty() {
                    ScreenDamage::None
                } else {
                    ScreenDamage::Rows(spans)
                }
            }
        };
        self.inner.reset_damage();

        if forced_full { ScreenDamage::Full } else { damage }
    }
}

impl std::fmt::Debug for Terminal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Terminal")
            .field("size", &self.size)
            .field("title", &self.title)
            .finish_non_exhaustive()
    }
}

fn shape_of(shape: alacritty_terminal::vte::ansi::CursorShape) -> CursorShape {
    use alacritty_terminal::vte::ansi::CursorShape as Upstream;
    match shape {
        Upstream::Block => CursorShape::Block,
        Upstream::Underline => CursorShape::Underline,
        Upstream::Beam => CursorShape::Beam,
        Upstream::HollowBlock => CursorShape::Block,
        Upstream::Hidden => CursorShape::Hidden,
    }
}

fn style_of(cell: &alacritty_terminal::term::cell::Cell) -> Style {
    let flags = cell.flags;
    Style {
        foreground: color_of(cell.fg),
        background: color_of(cell.bg),
        underline: if flags.contains(Flags::DOUBLE_UNDERLINE) {
            Underline::Double
        } else if flags.contains(Flags::UNDERCURL) {
            Underline::Curly
        } else if flags.contains(Flags::DOTTED_UNDERLINE) {
            Underline::Dotted
        } else if flags.contains(Flags::DASHED_UNDERLINE) {
            Underline::Dashed
        } else if flags.contains(Flags::UNDERLINE) {
            Underline::Single
        } else {
            Underline::None
        },
        underline_color: cell.underline_color().map(color_of),
        bold: flags.contains(Flags::BOLD),
        dim: flags.contains(Flags::DIM),
        italic: flags.contains(Flags::ITALIC),
        strikethrough: flags.contains(Flags::STRIKEOUT),
        inverse: flags.contains(Flags::INVERSE),
        hidden: flags.contains(Flags::HIDDEN),
    }
}

fn color_of(color: alacritty_terminal::vte::ansi::Color) -> Color {
    use alacritty_terminal::vte::ansi::{Color as Upstream, NamedColor as UpstreamNamed};
    match color {
        Upstream::Spec(rgb) => Color::Rgb { red: rgb.r, green: rgb.g, blue: rgb.b },
        Upstream::Indexed(index) => Color::Indexed(index),
        Upstream::Named(named) => Color::Named(match named {
            UpstreamNamed::Black => NamedColor::Black,
            UpstreamNamed::Red => NamedColor::Red,
            UpstreamNamed::Green => NamedColor::Green,
            UpstreamNamed::Yellow => NamedColor::Yellow,
            UpstreamNamed::Blue => NamedColor::Blue,
            UpstreamNamed::Magenta => NamedColor::Magenta,
            UpstreamNamed::Cyan => NamedColor::Cyan,
            UpstreamNamed::White => NamedColor::White,
            UpstreamNamed::BrightBlack => NamedColor::BrightBlack,
            UpstreamNamed::BrightRed => NamedColor::BrightRed,
            UpstreamNamed::BrightGreen => NamedColor::BrightGreen,
            UpstreamNamed::BrightYellow => NamedColor::BrightYellow,
            UpstreamNamed::BrightBlue => NamedColor::BrightBlue,
            UpstreamNamed::BrightMagenta => NamedColor::BrightMagenta,
            UpstreamNamed::BrightCyan => NamedColor::BrightCyan,
            UpstreamNamed::BrightWhite => NamedColor::BrightWhite,
            UpstreamNamed::Cursor => NamedColor::Cursor,
            // Dim and bright variants of the foreground resolve to the theme's
            // foreground; a consumer applies its own dimming from the flag.
            UpstreamNamed::Foreground
            | UpstreamNamed::DimForeground
            | UpstreamNamed::BrightForeground => NamedColor::Foreground,
            UpstreamNamed::Background => NamedColor::Background,
            UpstreamNamed::DimBlack => NamedColor::Black,
            UpstreamNamed::DimRed => NamedColor::Red,
            UpstreamNamed::DimGreen => NamedColor::Green,
            UpstreamNamed::DimYellow => NamedColor::Yellow,
            UpstreamNamed::DimBlue => NamedColor::Blue,
            UpstreamNamed::DimMagenta => NamedColor::Magenta,
            UpstreamNamed::DimCyan => NamedColor::Cyan,
            UpstreamNamed::DimWhite => NamedColor::White,
        }),
    }
}
