//! One line of editable text: what a chip's rename field edits.
//!
//! Byte offsets on character boundaries. The selection runs from `anchor`
//! to `head`; an empty one is the caret. Text an input method is still
//! composing is `marked`, a range of the text. Offsets an input method
//! speaks in are UTF-16, converted here.

use std::ops::Range;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Line {
    text: String,
    anchor: usize,
    head: usize,
    marked: Option<Range<usize>>,
}

impl Line {
    /// The whole text, selected, as a rename starts.
    pub fn selected(text: &str) -> Self {
        Self { text: text.to_owned(), anchor: 0, head: text.len(), marked: None }
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn selection(&self) -> Range<usize> {
        self.anchor.min(self.head)..self.anchor.max(self.head)
    }

    pub fn head(&self) -> usize {
        self.head
    }

    pub fn marked(&self) -> Option<Range<usize>> {
        self.marked.clone()
    }

    /// Typing: the selection, or what is being composed, becomes `text`.
    pub fn insert(&mut self, text: &str) {
        let range = self.marked.take().unwrap_or_else(|| self.selection());
        self.replace(range, text);
    }

    /// An input method's composing text, in place of the selection or of
    /// what it composed before. Committed by `insert`, dropped by `unmark`.
    pub fn mark(&mut self, text: &str) {
        let range = self.marked.take().unwrap_or_else(|| self.selection());
        let start = range.start;
        self.replace(range, text);
        self.marked = (!text.is_empty()).then(|| start..start + text.len());
    }

    pub fn unmark(&mut self) {
        self.marked = None;
    }

    pub fn backspace(&mut self) {
        let range = self.selection();
        if range.is_empty() {
            let start = self.previous(self.head);
            self.replace(start..self.head, "");
        } else {
            self.replace(range, "");
        }
    }

    pub fn delete(&mut self) {
        let range = self.selection();
        if range.is_empty() {
            let end = self.next(self.head);
            self.replace(self.head..end, "");
        } else {
            self.replace(range, "");
        }
    }

    pub fn left(&mut self, extend: bool) {
        let range = self.selection();
        let to = if !extend && !range.is_empty() { range.start } else { self.previous(self.head) };
        self.move_to(to, extend);
    }

    pub fn right(&mut self, extend: bool) {
        let range = self.selection();
        let to = if !extend && !range.is_empty() { range.end } else { self.next(self.head) };
        self.move_to(to, extend);
    }

    pub fn home(&mut self, extend: bool) {
        self.move_to(0, extend);
    }

    pub fn end(&mut self, extend: bool) {
        self.move_to(self.text.len(), extend);
    }

    pub fn select_all(&mut self) {
        self.anchor = 0;
        self.head = self.text.len();
    }

    /// UTF-16 units before byte offset `at`.
    pub fn utf16(&self, at: usize) -> usize {
        self.text[..at.min(self.text.len())].encode_utf16().count()
    }

    /// The byte offset after `units` UTF-16 units, on a character boundary.
    pub fn from_utf16(&self, units: usize) -> usize {
        let mut seen = 0;
        for (offset, c) in self.text.char_indices() {
            if seen >= units {
                return offset;
            }
            seen += c.len_utf16();
        }
        self.text.len()
    }

    fn move_to(&mut self, to: usize, extend: bool) {
        self.head = to;
        if !extend {
            self.anchor = to;
        }
    }

    fn replace(&mut self, range: Range<usize>, text: &str) {
        self.text.replace_range(range.clone(), text);
        self.head = range.start + text.len();
        self.anchor = self.head;
    }

    fn previous(&self, at: usize) -> usize {
        self.text[..at].char_indices().next_back().map_or(0, |(offset, _)| offset)
    }

    fn next(&self, at: usize) -> usize {
        self.text[at..].chars().next().map_or(at, |c| at + c.len_utf8())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rename_starts_selected_and_typing_replaces_it() {
        let mut line = Line::selected("ssh");
        line.insert("b");
        line.insert("astion");
        assert_eq!(line.text(), "bastion");
        assert_eq!(line.selection(), 7..7);
    }

    #[test]
    fn the_caret_moves_and_deletes_by_character() {
        let mut line = Line::selected("中文ab");
        line.end(false);
        line.backspace();
        line.home(false);
        line.right(false);
        line.delete();
        assert_eq!(line.text(), "中a");
        line.left(false);
        line.right(true);
        assert_eq!(&line.text()[line.selection()], "中");
        line.select_all();
        line.backspace();
        assert_eq!(line.text(), "");
        line.backspace();
        assert_eq!(line.text(), "");
    }

    #[test]
    fn an_arrow_collapses_a_selection_to_its_side() {
        let mut line = Line::selected("abc");
        line.left(false);
        assert_eq!(line.selection(), 0..0);
        line.select_all();
        line.right(false);
        assert_eq!(line.selection(), 3..3);
    }

    #[test]
    fn composing_replaces_itself_and_commits_once() {
        let mut line = Line::selected("x");
        line.mark("n");
        line.mark("ni");
        assert_eq!(line.text(), "ni");
        assert_eq!(line.marked(), Some(0..2));
        line.insert("你");
        assert_eq!(line.text(), "你");
        assert_eq!(line.marked(), None);
        line.mark("h");
        line.unmark();
        assert_eq!(line.text(), "你h");
    }

    #[test]
    fn utf16_offsets_land_on_characters() {
        let line = Line::selected("a😀b");
        assert_eq!(line.utf16(line.text().len()), 4);
        assert_eq!(line.from_utf16(1), 1);
        assert_eq!(line.from_utf16(3), 5);
        assert_eq!(line.from_utf16(9), 6);
    }
}
