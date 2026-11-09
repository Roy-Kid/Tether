//! A one-line text field in the chrome: a chip being renamed.
//!
//! Return submits, Escape cancels, and losing the focus submits, as the
//! Mac chip's `TextField` does. Typing and an input method's composing
//! text arrive through GPUI's input handler; editing keys are handled here.

use std::ops::Range;

use gpui::{
    Bounds, Context, ElementInputHandler, EntityInputHandler, EventEmitter, FocusHandle,
    KeyDownEvent, Pixels, Render, Subscription, UTF16Selection, Window, canvas, div, prelude::*,
    px, rgb,
};

use crate::{Chrome, Line};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FieldEvent {
    Submit(String),
    Cancel,
}

pub struct TextField {
    line: Line,
    focus: FocusHandle,
    text: u32,
    accent: u32,
    done: bool,
    _blur: Subscription,
}

impl EventEmitter<FieldEvent> for TextField {}

impl TextField {
    /// Focused, with `text` selected. `color` is the text's, `accent` the selection's.
    pub fn new(
        text: &str,
        color: u32,
        accent: u32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        let blur = cx.on_blur(&focus, window, |this, _, cx| this.finish(true, cx));
        Self { line: Line::selected(text), focus, text: color, accent, done: false, _blur: blur }
    }

    fn finish(&mut self, submit: bool, cx: &mut Context<Self>) {
        if self.done {
            return;
        }
        self.done = true;
        cx.emit(if submit {
            FieldEvent::Submit(self.line.text().to_owned())
        } else {
            FieldEvent::Cancel
        });
    }

    fn key_down(&mut self, event: &KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        let modifiers = event.keystroke.modifiers;
        let extend = modifiers.shift;
        match event.keystroke.key.as_str() {
            "enter" => self.finish(true, cx),
            "escape" => self.finish(false, cx),
            "backspace" => self.line.backspace(),
            "delete" => self.line.delete(),
            "left" if modifiers.platform => self.line.home(extend),
            "right" if modifiers.platform => self.line.end(extend),
            "left" => self.line.left(extend),
            "right" => self.line.right(extend),
            "home" | "up" => self.line.home(extend),
            "end" | "down" => self.line.end(extend),
            "a" if modifiers.platform => self.line.select_all(),
            // Text goes to the input handler; other chords to whoever owns them.
            _ => return,
        }
        cx.stop_propagation();
        cx.notify();
    }

    fn utf16_range(&self, range: Range<usize>) -> Range<usize> {
        self.line.utf16(range.start)..self.line.utf16(range.end)
    }
}

impl EntityInputHandler for TextField {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        adjusted: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let bytes = self.line.from_utf16(range.start)..self.line.from_utf16(range.end);
        *adjusted = Some(self.utf16_range(bytes.clone()));
        Some(self.line.text()[bytes].to_owned())
    }

    fn selected_text_range(
        &mut self,
        _: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection { range: self.utf16_range(self.line.selection()), reversed: false })
    }

    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        self.line.marked().map(|range| self.utf16_range(range))
    }

    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.line.unmark();
        cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        _: Option<Range<usize>>,
        text: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.line.insert(text);
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _: Option<Range<usize>>,
        text: &str,
        _: Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.line.mark(text);
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        _: Range<usize>,
        element: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        Some(element)
    }

    fn character_index_for_point(
        &mut self,
        _: gpui::Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        None
    }
}

impl Render for TextField {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let text = self.line.text();
        let selection = self.line.selection();
        let marked = self.line.marked();
        let focus = self.focus.clone();
        let entity = cx.entity();
        let span = |range: Range<usize>| div().flex_none().child(text[range].to_owned());
        // What is being composed is underlined; a selection is tinted; an
        // empty one is the caret.
        let (middle, cut) = match marked {
            Some(range) => (span(range.clone()).underline(), range),
            None if selection.is_empty() => (
                div()
                    .flex_none()
                    .w(px(Chrome::HAIRLINE))
                    .h(px(Chrome::TITLE + 2.0))
                    .bg(rgb(self.text)),
                selection,
            ),
            None => (span(selection.clone()).bg(rgb(self.accent).opacity(0.40)), selection),
        };
        div()
            .id("rename-field")
            .relative()
            .flex()
            .flex_row()
            .items_center()
            .overflow_hidden()
            .max_w(px(Chrome::TAB_TITLE_WIDTH))
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::key_down))
            .child(
                canvas(
                    |_, _, _| (),
                    move |bounds, (), window, cx| {
                        window.handle_input(&focus, ElementInputHandler::new(bounds, entity), cx);
                    },
                )
                .absolute()
                .size_full(),
            )
            .child(span(0..cut.start))
            .child(middle)
            .child(span(cut.end..text.len()))
    }
}
