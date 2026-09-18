//! The engine: bytes in, screen state and damage out.

use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::Processor;

use crate::damage::{Changes, RowSpan, ScreenDamage};
use crate::input::Input;
use crate::screen::{Cell, Cursor, CursorShape, Modes, Screen};
use crate::scroll::{Scroll, Viewport};
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

/// The narrowest grid the engine can reflow into.
///
/// One column hangs it. A wide character occupies two columns and cannot be
/// placed in a row that has one, and reflowing scrollback into such a grid
/// never terminates — measured: resizing a filled 40×12 terminal to 1×2
/// allocated 1.6GB in twenty seconds and was killed, while 2×1 completes.
/// Rows have no such floor; a one-row terminal is odd but finite.
///
/// Clamping here rather than letting it through is what this crate is for:
/// an engine's limits stop at the boundary instead of becoming a hang a
/// consumer has to know about (spec §8). A frontend whose window is dragged
/// to a sliver reaches this every time.
const MINIMUM_COLUMNS: u16 = 2;

fn usable(size: ScreenSize) -> ScreenSize {
    ScreenSize::new(size.columns.max(MINIMUM_COLUMNS), size.rows.max(1))
}

/// How a terminal is configured.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Options {
    /// How many lines of scrollback to keep.
    ///
    /// A real cost, not a preference: every line is retained memory, and a
    /// resize reflows all of them. An embedder on a phone and one on a
    /// workstation want different numbers.
    pub scrollback_lines: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self { scrollback_lines: 10_000 }
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
    /// Set when a title arrived and no consumer has been told yet.
    title_changed: bool,
    /// History depth at the last `take_changes`, so the next one can say how
    /// many lines went past.
    last_history: usize,
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
        Self::with_options(size, Options::default())
    }

    pub fn with_options(size: ScreenSize, options: Options) -> Self {
        let size = usable(size);
        let sink = Sink::default();
        let config = Config { scrolling_history: options.scrollback_lines, ..Config::default() };
        let inner = Term::new(config, &Dims { size }, sink.clone());

        Self {
            inner,
            parser: Processor::new(),
            sink,
            size,
            last_cursor: None,
            last_modes: None,
            title: String::new(),
            title_changed: false,
            last_history: 0,
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
        self.adopt_title();
    }

    /// Takes any title the bytes just carried.
    ///
    /// Done here rather than in [`Self::take_changes`] because `title` is
    /// readable on its own, and a consumer that renders from `screen` and
    /// `title` — which is what a frontend does — never calls `take_changes`
    /// at all. Leaving the adoption there meant the window title a remote
    /// program set never arrived: measured, an `OSC 0` title stayed empty
    /// until something asked for damage.
    fn adopt_title(&mut self) {
        let arrived = {
            let mut collected = self.sink.0.lock().expect("terminal event sink poisoned");
            collected.title.take()
        };
        if let Some(title) = arrived {
            self.title = title;
            self.title_changed = true;
        }
    }

    /// Changes the screen size.
    ///
    /// Always reported as full damage: reflow can move every line.
    pub fn resize(&mut self, size: ScreenSize) {
        let size = usable(size);
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

        // `feed` already adopted anything that arrived; this only reports
        // whether it is new to *this* consumer since the last call.
        self.adopt_title();
        let title = std::mem::replace(&mut self.title_changed, false).then(|| self.title.clone());

        let bell = {
            let mut collected = self.sink.0.lock().expect("sink poisoned");
            std::mem::replace(&mut collected.bell, false)
        };

        // How much went past since the last time anyone asked. Measured from
        // the history's depth rather than counted during parsing, because the
        // engine is the thing that decides what a scroll is.
        //
        // It saturates: once the history is full, lines keep going past and
        // the depth stops growing, so this reports zero for a terminal that
        // has been running long enough. A consumer using it to hold a
        // scrollback view steady must treat it as a floor, not a total —
        // which is why the viewport is reported as a position as well.
        let history = self.history_lines();
        let scrolled_lines = history.saturating_sub(self.last_history);
        self.last_history = history;

        Changes {
            screen,
            cursor: cursor_changed.then_some(cursor),
            title,
            modes: modes_changed.then_some(modes),
            scrolled_lines,
            bell,
        }
    }

    /// Turns something the person did into the bytes to send.
    ///
    /// A method rather than a free function because the encoding depends on
    /// modes the *remote* program set: the same arrow key is `ESC [ A` or
    /// `ESC O A` depending on state only the terminal knows.
    pub fn encode(&self, input: &Input) -> Vec<u8> {
        crate::input::encode(input, self.read_modes())
    }

    /// Where the viewport is, and how much history is behind it.
    pub fn viewport(&self) -> Viewport {
        Viewport { offset: self.inner.grid().display_offset(), history: self.history_lines() }
    }

    /// How many lines have scrolled off the top and are still kept.
    ///
    /// Zero while the alternate screen is up: a full-screen program's output
    /// is not scrollback, and the engine keeps none for it.
    pub fn history_lines(&self) -> usize {
        self.inner.grid().history_size()
    }

    /// Moves the viewport over the history.
    ///
    /// Clamped by the engine at both ends, so a caller can send a page up at
    /// the top or a page down at the bottom without checking first — which is
    /// what a scroll wheel does constantly.
    pub fn scroll(&mut self, scroll: Scroll) {
        use alacritty_terminal::grid::Scroll as Engine;

        let before = self.inner.grid().display_offset();
        self.inner.scroll_display(match scroll {
            Scroll::Lines(count) => Engine::Delta(count),
            Scroll::PageUp => Engine::PageUp,
            Scroll::PageDown => Engine::PageDown,
            Scroll::Oldest => Engine::Top,
            Scroll::Live => Engine::Bottom,
        });

        // Only a viewport that actually moved is a change. A wheel at the end
        // of its travel would otherwise repaint the screen on every notch.
        if self.inner.grid().display_offset() != before {
            self.pending_full_damage = true;
            self.dirty = true;
        }
    }

    /// A snapshot of the visible screen.
    pub fn screen(&self) -> Screen {
        let grid = self.inner.grid();
        let mut rows = Vec::with_capacity(self.size.rows as usize);

        // `Line(0)` is the top of the *live* screen and history is negative,
        // so the viewport is applied here rather than assumed away. Reading
        // `0..rows` regardless is how scrolling can move the engine's
        // viewport and change nothing a consumer can see.
        let offset = grid.display_offset() as i32;

        for row in 0..self.size.rows as i32 {
            let line = row - offset;
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

                // A wide character reports two columns only when the engine
                // really did reserve the column to its right for it.
                //
                // Asking whether a column *index* remains is not the same
                // question, and getting them confused overflows the row:
                // reflow onto a narrower screen can leave a `WIDE_CHAR` whose
                // spacer is gone, with an ordinary cell beside it — measured
                // by the fuzzer, a two-column row then claimed three. The
                // spacer is the engine's own record of the reservation, so it
                // is what gets asked.
                let wide = cell.flags.contains(Flags::WIDE_CHAR)
                    && (column + 1 < self.size.columns as usize)
                    && grid[Line(line)][Column(column + 1)].flags.contains(Flags::WIDE_CHAR_SPACER);

                cells.push(Cell { text, width: if wide { 2 } else { 1 }, style: style_of(cell) });
            }
            rows.push(cells);
        }

        Screen::new(self.size, self.read_cursor(), self.read_modes(), self.viewport(), rows)
    }

    fn read_cursor(&self) -> Cursor {
        let point = self.inner.grid().cursor.point;
        let mode = self.inner.mode();

        // The cursor sits on the live screen. Scrolling back moves the
        // viewport away from it, and a cursor drawn at its live row while
        // someone reads history would blink over unrelated text.
        let offset = self.inner.grid().display_offset() as i32;
        let row = point.line.0 + offset;
        let within = row >= 0 && row < self.size.rows as i32;

        let visible = mode.contains(TermMode::SHOW_CURSOR) && within;

        Cursor {
            position: Position::new(
                row.clamp(0, self.size.rows as i32 - 1) as u16,
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
                let rows = self.size.rows;
                let last_column = self.size.columns.saturating_sub(1);

                // Clamped, not trusted. The engine can report a span wider
                // than the grid after a shrinking resize — measured: a
                // 15-column grid reported `right: 15` several frames after
                // being narrowed from 39. A renderer that indexed by that
                // would run off the end of its own row, so the bound stops
                // here rather than reaching a consumer (spec §8).
                let spans: Vec<RowSpan> = lines
                    .filter_map(|line| {
                        let row = u16::try_from(line.line).ok()?;
                        if row >= rows {
                            return None;
                        }
                        let first = u16::try_from(line.left).unwrap_or(u16::MAX).min(last_column);
                        let last = u16::try_from(line.right).unwrap_or(u16::MAX).min(last_column);
                        Some(RowSpan { row, first_column: first.min(last), last_column: last })
                    })
                    .collect();

                if spans.is_empty() { ScreenDamage::None } else { ScreenDamage::Rows(spans) }
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
