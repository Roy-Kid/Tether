//! The input method, as the Mac `KeyCaptureView` is its client.
//!
//! Text the input method commits is typed, as a key with that text. Text it
//! is still composing is kept here and drawn at the cursor, not sent: a
//! candidate has not been chosen. Its candidates open at the cursor's cell.

use std::ops::Range;

use gpui::{Bounds, Context, EntityInputHandler, Pixels, UTF16Selection, Window, point, px, size};
use tether_ffi::{KeyModifiers, KeyPress, TerminalInput};

use crate::workspace::Desktop;

impl Desktop {
    fn utf16_len(&self) -> usize {
        self.marked.encode_utf16().count()
    }

    fn show_marked(&self) {
        if let Some(pane) = self.workspaces.selected().and_then(|id| self.panes.get(&id)) {
            pane.preedit(&self.marked);
        }
    }

    fn set_marked(&mut self, marked: &str) {
        if self.marked != marked {
            self.marked = marked.to_owned();
            self.show_marked();
        }
    }
}

impl EntityInputHandler for Desktop {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        adjusted: &mut Option<Range<usize>>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<String> {
        let units: Vec<u16> = self.marked.encode_utf16().collect();
        let range = range.start.min(units.len())..range.end.min(units.len());
        *adjusted = Some(range.clone());
        String::from_utf16(&units[range]).ok()
    }

    fn selected_text_range(
        &mut self,
        _ignore_disabled_input: bool,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        let end = self.utf16_len();
        Some(UTF16Selection { range: end..end, reversed: false })
    }

    fn marked_text_range(
        &self,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Range<usize>> {
        (!self.marked.is_empty()).then(|| 0..self.utf16_len())
    }

    fn unmark_text(&mut self, _window: &mut Window, _cx: &mut Context<Self>) {
        self.set_marked("");
    }

    /// `insertText`: what the input method committed is typed.
    fn replace_text_in_range(
        &mut self,
        _range: Option<Range<usize>>,
        text: &str,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) {
        self.set_marked("");
        if !text.is_empty() {
            self.type_text(text);
        }
    }

    /// `setMarkedText`.
    fn replace_and_mark_text_in_range(
        &mut self,
        _range: Option<Range<usize>>,
        text: &str,
        _selected: Option<Range<usize>>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) {
        self.set_marked(text);
    }

    /// `firstRect`: the cursor's cell.
    fn bounds_for_range(
        &mut self,
        _range: Range<usize>,
        _element: Bounds<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let pane = self.workspaces.selected().and_then(|id| self.panes.get(&id))?;
        let caret = pane.caret_in_window()?;
        Some(Bounds::new(point(px(caret.x), px(caret.y)), size(px(caret.width), px(caret.height))))
    }

    fn character_index_for_point(
        &mut self,
        _point: gpui::Point<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<usize> {
        None
    }
}

/// What typing `text` sends: a key with that text and no modifiers.
pub fn typed(text: &str) -> TerminalInput {
    TerminalInput::Key {
        key: KeyPress::Char { text: text.to_owned() },
        modifiers: KeyModifiers::default(),
    }
}
