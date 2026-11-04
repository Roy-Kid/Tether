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
