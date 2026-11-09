//! The pointer over a terminal: the Mac `KeyCaptureView` mouse handling.
//!
//! A program that turned mouse reporting on hears presses, releases and
//! (by mode) motion, unless Shift is held. Otherwise a drag selects: past a
//! 4pt slop for a single click, by word on a double click, by line on a
//! triple, and Shift extends the selection on screen. A drag that ends
//! copies; a click that never moved clears.

use tether_desktop::links;
use tether_desktop::selection::{self, Kind, Point, Selection};
use tether_ffi::{
    KeyModifiers, MouseTracking, PointerButton, PointerPhase, TerminalInput, TerminalLink,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cursor {
    Arrow,
    Hand,
    Text,
}

use crate::pane::Pane;

/// `dragSlop`.
const DRAG_SLOP: f32 = 4.0;

#[derive(Default)]
pub struct Pointer {
    /// The button a program heard pressed. `None` while a drag selects instead.
    held: Option<PointerButton>,
    /// The last cell a move was reported at, so a pointer in one cell is quiet.
    reported: Option<(u16, u16)>,
    kind: Option<Kind>,
    anchor: Option<Point>,
    head: Option<Point>,
    /// A click that never moved stays unarmed.
    armed: bool,
    start: (f32, f32),
}

/// What a press carried besides its place.
#[derive(Clone, Copy, Default)]
pub struct Press {
    pub clicks: usize,
    pub shift: bool,
    pub alt: bool,
    pub control: bool,
}

impl Press {
    fn modifiers(self) -> KeyModifiers {
        KeyModifiers { shift: self.shift, alt: self.alt, control: self.control }
    }
}

impl Pane {
    pub(crate) fn tracking(&self) -> MouseTracking {
        self.frame.as_ref().map(|frame| frame.mouse).unwrap_or_default()
    }

    /// `mouseDown`, `rightMouseDown`, `otherMouseDown`.
    pub fn press(&mut self, button: PointerButton, x: f32, y: f32, press: Press) {
        self.pointer = Pointer { start: (x, y), ..Pointer::default() };
        let reports = self.tracking() != MouseTracking::Off && !press.shift;
        if reports && let Some((row, column)) = self.cell_within(x, y) {
            self.pointer.held = Some(button);
            self.report(button, PointerPhase::Press, row, column, press.modifiers());
            return;
        }
        if button != PointerButton::Left {
            return;
        }
        let Some((row, column)) = self.cell_within(x, y) else { return };
        let point = Point::new(row.into(), column.into());
        let (kind, anchor, armed) = match (press.clicks, press.shift, self.selection) {
            (clicks, _, _) if clicks >= 3 => (Kind::Line, point, true),
            (2, _, _) => (Kind::Word, point, true),
            (_, true, Some(existing)) => (Kind::Character, existing.anchor, true),
            _ => (Kind::Character, point, false),
        };
        self.pointer.kind = Some(kind);
        self.pointer.anchor = Some(anchor);
        self.pointer.head = Some(point);
        self.pointer.armed = armed;
        if armed {
            self.highlight(kind, anchor, point);
        }
    }

    /// `mouseDragged`, and `mouseMoved` while the program wants every move.
    pub fn moved(&mut self, x: f32, y: f32, pressed: bool, press: Press) {
        if let Some(button) = self.pointer.held {
            if matches!(self.tracking(), MouseTracking::Drag | MouseTracking::Any) {
                self.report_move(button, x, y, press);
            }
            return;
        }
        if !pressed {
            if self.tracking() == MouseTracking::Any && self.cell_within(x, y).is_some() {
                self.report_move(PointerButton::None, x, y, press);
            }
            return;
        }
        let (Some(anchor), Some(kind)) = (self.pointer.anchor, self.pointer.kind) else { return };
        let (dx, dy) = (x - self.pointer.start.0, y - self.pointer.start.1);
        if !self.pointer.armed && dx.hypot(dy) < DRAG_SLOP {
            return;
        }
        let (row, column) = self.cell_at(x, y);
        let head = Point::new(row.into(), column.into());
        self.pointer.armed = true;
        self.pointer.head = Some(head);
        self.highlight(kind, anchor, head);
    }

    /// `mouseUp`. Returns the text a finished drag copies.
    pub fn release(
        &mut self,
        button: PointerButton,
        x: f32,
        y: f32,
        press: Press,
    ) -> Option<String> {
        let pointer = std::mem::take(&mut self.pointer);
        if let Some(held) = pointer.held {
            let (row, column) = self.cell_at(x, y);
            self.report(held, PointerPhase::Release, row, column, press.modifiers());
            return None;
        }
        if button != PointerButton::Left {
            return None;
        }
        let (Some(anchor), Some(kind)) = (pointer.anchor, pointer.kind) else { return None };
        if !pointer.armed {
            self.set_selection(None);
            return None;
        }
        self.highlight(kind, anchor, pointer.head.unwrap_or(anchor));
        self.copy()
    }

    /// The link at a window point, if the text there names one.
    pub fn link_at(&self, x: f32, y: f32) -> Option<TerminalLink> {
        let (row, column) = self.cell_within(x, y)?;
        self.session.link_at(row, column)
    }

    /// ⌘ over a web link underlines it; anything else clears the underline.
    pub fn hover(&mut self, x: f32, y: f32, command: bool) {
        let link = command
            .then(|| self.link_at(x, y))
            .flatten()
            .filter(|link| links::web_address(link).is_some());
        if link != self.hovered {
            self.hovered = link;
            self.draw();
        }
    }

    /// What the pointer looks like here (`resetCursorRects`): an arrow for a
    /// program that takes the mouse, a hand over a link, a text beam otherwise.
    pub fn cursor(&self) -> Cursor {
        if self.tracking() != MouseTracking::Off {
            Cursor::Arrow
        } else if self.hovered.is_some() {
            Cursor::Hand
        } else {
            Cursor::Text
        }
    }

    /// ⌘C: the selection on screen.
    pub fn copy(&self) -> Option<String> {
        let text = selection::text(self.frame.as_ref()?, self.selection?);
        (!text.is_empty()).then_some(text)
    }

    fn highlight(&mut self, kind: Kind, from: Point, to: Point) {
        let chosen = self.frame.as_ref().and_then(|frame| selection::select(kind, from, to, frame));
        self.set_selection(chosen);
    }

    fn set_selection(&mut self, selection: Option<Selection>) {
        if self.selection != selection {
            self.selection = selection;
            self.draw();
        }
    }

    fn report_move(&mut self, button: PointerButton, x: f32, y: f32, press: Press) {
        let cell = self.cell_at(x, y);
        if self.pointer.reported == Some(cell) {
            return;
        }
        self.pointer.reported = Some(cell);
        self.report(button, PointerPhase::Move, cell.0, cell.1, press.modifiers());
    }

    fn report(
        &self,
        button: PointerButton,
        phase: PointerPhase,
        row: u16,
        column: u16,
        modifiers: KeyModifiers,
    ) {
        let input = TerminalInput::Pointer { button, phase, column, row, modifiers };
        if let Err(error) = self.session.send(input) {
            eprintln!("tether-desktop: pointer: {error}");
        }
    }
}
