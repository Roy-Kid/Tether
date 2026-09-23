//! Finding what a point on the screen names.
//!
//! Shape, not truth: this says "the text under the pointer looks like a path
//! and here is where it is", and never whether the file exists. That is a
//! question for whoever holds the connection, and a terminal that asked it
//! would be a terminal that reached a network (spec §3).
//!
//! Everything read here is remote text (spec §18). The finder walks a
//! bounded window of cells, allocates in proportion to it, and has its own
//! fuzz target.

use std::ops::Range;

/// Where a link is drawn: one span per screen row it occupies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkSpan {
    /// A viewport row, as [`crate::Position::row`].
    pub row: u16,
    /// The first column, inclusive.
    pub start: u16,
    /// One past the last column.
    pub end: u16,
}

/// What a link points at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkTarget {
    /// The URI a program attached with `OSC 8`, exactly as it sent it.
    Hyperlink(String),
    /// A web address in the text.
    Url(String),
    /// Text shaped like a path, relative or absolute, with the line and
    /// column it carried (`src/main.rs:12:5`) kept apart.
    Path { path: String, line: Option<u32>, column: Option<u32> },
}

/// Something on screen that names a place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    /// What is drawn there, as a person would read it.
    pub text: String,
    pub target: LinkTarget,
    pub spans: Vec<LinkSpan>,
}

/// One drawn character of a logical line, and where it is.
#[derive(Debug, Clone)]
pub(crate) struct Glyph {
    pub text: String,
    pub row: u16,
    pub column: u16,
    pub width: u16,
}

/// Longest line the finder will read, in characters. A path longer than
/// this is not one anybody points at, and a program that prints a
/// megabyte without a newline should not make pointing slow.
pub(crate) const LINE_LIMIT: usize = 4096;

/// The link in `line` covering the glyph at `hit`, if its text is shaped
/// like one.
pub(crate) fn find(line: &[Glyph], hit: usize) -> Option<Link> {
    let token = token_around(line, hit)?;
    let (core, suffix) = trim(line, token);
    if core.is_empty() || !covers(&core, &suffix, hit) {
        return None;
    }
    let text: String = line[core.clone()].iter().map(|glyph| glyph.text.as_str()).collect();
    let tail = suffix.clone().map(|range| line[range].iter().map(|g| g.text.as_str()).collect());
    let target = classify(&text, &tail)?;
    // Underlined whole, `:12:5` included: it is what the person pointed at,
    // even though the path is only what comes before it.
    let drawn = core.start..suffix.map_or(core.end, |range| range.end);
    Some(Link { text, target, spans: spans(&line[drawn]) })
}

/// Whether the pointer is on the path or on its `:12:5`.
fn covers(core: &Range<usize>, suffix: &Option<Range<usize>>, hit: usize) -> bool {
    core.contains(&hit) || suffix.as_ref().is_some_and(|range| range.contains(&hit))
}

/// Characters that end a word someone could mean as a path. Not `:` —
/// URLs and line numbers use it — and not `.`, which names use.
fn separates(text: &str) -> bool {
    text.chars().all(|c| {
        c.is_whitespace()
            || matches!(
                c,
                '"' | '\'' | '`' | '<' | '>' | '|' | '(' | ')' | '[' | ']' | '{' | '}' | ',' | ';'
            )
    })
}

fn token_around(line: &[Glyph], hit: usize) -> Option<Range<usize>> {
    if hit >= line.len() || separates(&line[hit].text) {
        return None;
    }
    let mut start = hit;
    while start > 0 && !separates(&line[start - 1].text) {
        start -= 1;
    }
    let mut end = hit + 1;
    while end < line.len() && !separates(&line[end].text) {
        end += 1;
    }
    Some(start..end)
}

/// Strips what surrounds a path in prose — a leading `@` (an agent's file
/// mention), trailing sentence punctuation — and separates a `:line:column`
/// suffix. Returns the path's glyphs and the suffix's, if any.
fn trim(line: &[Glyph], mut token: Range<usize>) -> (Range<usize>, Option<Range<usize>>) {
    while token.start < token.end && line[token.start].text == "@" {
        token.start += 1;
    }
    while token.start < token.end
        && matches!(line[token.end - 1].text.as_str(), "." | ":" | "!" | "?")
    {
        token.end -= 1;
    }

    // `:12` or `:12:5` at the end, read from the right.
    let mut cut = token.end;
    let mut numbers = 0;
    loop {
        let mut digits = cut;
        while digits > token.start && line[digits - 1].text.chars().all(|c| c.is_ascii_digit()) {
            digits -= 1;
        }
        if digits == cut || digits == token.start || line[digits - 1].text != ":" || numbers == 2 {
            break;
        }
        cut = digits - 1;
        numbers += 1;
    }
    if numbers > 0 && cut > token.start {
        (token.start..cut, Some(cut..token.end))
    } else {
        (token, None)
    }
}

fn classify(text: &str, suffix: &Option<String>) -> Option<LinkTarget> {
    if text.starts_with("https://") || text.starts_with("http://") {
        let url = match suffix {
            Some(suffix) => format!("{text}{suffix}"),
            None => text.to_owned(),
        };
        return (url.len() > "https://".len()).then_some(LinkTarget::Url(url));
    }
    if text.contains("://") {
        return None;
    }
    if !looks_like_path(text) {
        return None;
    }
    let mut numbers = suffix
        .as_deref()
        .unwrap_or("")
        .split(':')
        .filter(|part| !part.is_empty())
        .map(|part| part.parse::<u32>().ok());
    let line = numbers.next().flatten();
    let column = numbers.next().flatten();
    Some(LinkTarget::Path { path: text.to_owned(), line, column })
}

/// A separator, a home-relative start, or a name with an extension that has
/// a letter in it — so `plot.png` is a file and `3.14` is a number.
fn looks_like_path(text: &str) -> bool {
    if matches!(text, "/" | "." | ".." | "~") {
        return false;
    }
    if !text.chars().all(|c| c.is_alphanumeric() || "/._-~+@%=#".contains(c)) {
        return false;
    }
    if text.contains('/') || text.starts_with('~') {
        return true;
    }
    match text.rsplit_once('.') {
        Some((stem, extension)) => {
            !stem.is_empty()
                && !extension.is_empty()
                && extension.len() <= 10
                && extension.chars().any(|c| c.is_alphabetic())
                && extension.chars().all(|c| c.is_alphanumeric())
        }
        None => false,
    }
}

/// The glyphs' screen extent, one span per row.
pub(crate) fn spans(glyphs: &[Glyph]) -> Vec<LinkSpan> {
    let mut spans: Vec<LinkSpan> = Vec::new();
    for glyph in glyphs {
        let end = glyph.column + glyph.width;
        match spans.last_mut() {
            Some(span) if span.row == glyph.row => span.end = end,
            _ => spans.push(LinkSpan { row: glyph.row, start: glyph.column, end }),
        }
    }
    spans
}
