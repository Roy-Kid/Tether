//! What a point on the screen names, for a Swift consumer.

use tether_core::terminal::{Link, LinkTarget};

/// Where a link is drawn on one screen row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct LinkSpan {
    pub row: u16,
    /// First column, inclusive.
    pub start: u16,
    /// One past the last column.
    pub end: u16,
}

/// What a link points at. A path is shape, not truth: nothing has asked the
/// far side whether it exists.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkKind {
    /// The URI a program attached with `OSC 8`, exactly as sent.
    Hyperlink {
        uri: String,
    },
    Url {
        url: String,
    },
    /// Relative or absolute, as printed; `line` and `column` when it carried
    /// `:12:5`.
    Path {
        path: String,
        line: Option<u32>,
        column: Option<u32>,
    },
}

/// Something on screen that names a place, and where it is drawn.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalLink {
    pub text: String,
    pub kind: LinkKind,
    pub spans: Vec<LinkSpan>,
}

impl From<Link> for TerminalLink {
    fn from(link: Link) -> Self {
        Self {
            text: link.text,
            kind: match link.target {
                LinkTarget::Hyperlink(uri) => LinkKind::Hyperlink { uri },
                LinkTarget::Url(url) => LinkKind::Url { url },
                LinkTarget::Path { path, line, column } => LinkKind::Path { path, line, column },
            },
            spans: link
                .spans
                .into_iter()
                .map(|span| LinkSpan { row: span.row, start: span.start, end: span.end })
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tether_core::terminal::{Position, ScreenSize, Terminal};

    #[test]
    fn a_path_crosses_with_its_line_and_where_it_is_drawn() {
        let mut terminal = Terminal::new(ScreenSize::new(40, 2));
        terminal.feed(b"at src/main.rs:12:5\r\n");
        let link = TerminalLink::from(terminal.link_at(Position::new(0, 5)).unwrap());
        assert_eq!(
            link.kind,
            LinkKind::Path { path: "src/main.rs".to_owned(), line: Some(12), column: Some(5) }
        );
        assert_eq!(link.spans, [LinkSpan { row: 0, start: 3, end: 19 }]);
    }
}
