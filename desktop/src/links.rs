//! What pointing at a link does without a plugin: a web address opens in
//! the browser (`WorkspaceView.webAddress`). A path waits for the Files
//! plugin to say whether it exists, so until then it is neither underlined
//! nor opened.

use tether_ffi::{LinkKind, TerminalLink};

/// The address, when the link is an http or https page, printed or OSC 8.
pub fn web_address(link: &TerminalLink) -> Option<&str> {
    let text = match &link.kind {
        LinkKind::Url { url } => url.as_str(),
        LinkKind::Hyperlink { uri } => uri.as_str(),
        LinkKind::Path { .. } => return None,
    };
    let scheme = text.split_once(':')?.0.to_ascii_lowercase();
    matches!(scheme.as_str(), "http" | "https").then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn link(kind: LinkKind) -> TerminalLink {
        TerminalLink { text: String::new(), kind, spans: Vec::new() }
    }

    #[test]
    fn only_a_web_page_opens_by_itself() {
        assert_eq!(
            web_address(&link(LinkKind::Url { url: "https://zed.dev".into() })),
            Some("https://zed.dev")
        );
        assert_eq!(
            web_address(&link(LinkKind::Hyperlink { uri: "HTTP://a.b".into() })),
            Some("HTTP://a.b")
        );
        assert_eq!(
            web_address(&link(LinkKind::Hyperlink { uri: "file:///etc/hosts".into() })),
            None
        );
        assert_eq!(web_address(&link(LinkKind::Url { url: "ftp://x".into() })), None);
    }
}
