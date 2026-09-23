//! Where the far side's shell says it is.
//!
//! A shell with integration reports its working directory after every
//! command: `OSC 7 ; file://host/path`, or iTerm's `OSC 1337 ;
//! CurrentDir=/path`. The engine ignores both — they draw nothing — so they
//! are read here, from the same bytes, beside it.
//!
//! A scanner of its own rather than a hook in the engine's parser because
//! the parser offers none for these, and because it is remote input with a
//! small, fuzzable grammar (spec §18): bounded, byte-at-a-time, and resumed
//! across any split a network makes.

/// Longest report kept. A path is shorter than this; a sequence that is not
/// finished by then is abandoned rather than buffered without end.
const LIMIT: usize = 4096;

#[derive(Debug, Default)]
enum State {
    #[default]
    Ground,
    /// Just saw `ESC`.
    Escape,
    /// Inside an OSC, collecting its body.
    Command(Vec<u8>),
    /// Inside an OSC, just saw `ESC` — the start of `ST`, or not.
    CommandEscape(Vec<u8>),
    /// An OSC too long to be one of ours, skipped to its end.
    Skipping,
    SkippingEscape,
}

/// Reads working-directory reports out of a byte stream.
#[derive(Debug, Default)]
pub(crate) struct DirectoryScanner {
    state: State,
    current: Option<String>,
}

impl DirectoryScanner {
    pub fn current(&self) -> Option<&str> {
        self.current.as_deref()
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.state = match std::mem::take(&mut self.state) {
                State::Ground => match byte {
                    0x1b => State::Escape,
                    _ => State::Ground,
                },
                State::Escape => match byte {
                    b']' => State::Command(Vec::new()),
                    0x1b => State::Escape,
                    _ => State::Ground,
                },
                State::Command(mut body) => match byte {
                    0x07 => {
                        self.finish(&body);
                        State::Ground
                    }
                    0x1b => State::CommandEscape(body),
                    // A C0 control other than BEL or ESC cancels the
                    // sequence, as it does in the engine.
                    0x18 | 0x1a => State::Ground,
                    _ if body.len() >= LIMIT => State::Skipping,
                    _ => {
                        body.push(byte);
                        State::Command(body)
                    }
                },
                State::CommandEscape(body) => match byte {
                    b'\\' => {
                        self.finish(&body);
                        State::Ground
                    }
                    b']' => State::Command(Vec::new()),
                    _ => State::Ground,
                },
                State::Skipping => match byte {
                    0x07 | 0x18 | 0x1a => State::Ground,
                    0x1b => State::SkippingEscape,
                    _ => State::Skipping,
                },
                State::SkippingEscape => match byte {
                    b']' => State::Command(Vec::new()),
                    _ => State::Ground,
                },
            };
        }
    }

    fn finish(&mut self, body: &[u8]) {
        if let Some(path) = parse(body) {
            self.current = Some(path);
        }
    }
}

/// The absolute path a report names, if it is a report and names one.
fn parse(body: &[u8]) -> Option<String> {
    let body = std::str::from_utf8(body).ok()?;
    let path = if let Some(url) = body.strip_prefix("7;") {
        // `file://host/path`: the host is the far side's own name for
        // itself, and the path is what matters here.
        let rest = url.strip_prefix("file://")?;
        let slash = rest.find('/')?;
        decode(&rest[slash..])?
    } else {
        body.strip_prefix("1337;CurrentDir=")?.to_owned()
    };
    (path.starts_with('/') && !path.chars().any(char::is_control)).then_some(path)
}

/// Percent-decoding, refusing anything malformed rather than guessing.
fn decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = std::str::from_utf8(bytes.get(index + 1..index + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_escapes_are_refused() {
        assert_eq!(decode("/a%2"), None);
        assert_eq!(decode("/a%zz"), None);
        assert_eq!(decode("/a%20b"), Some("/a b".to_owned()));
    }

    #[test]
    fn a_cancelled_sequence_reports_nothing() {
        let mut scanner = DirectoryScanner::default();
        scanner.feed(b"\x1b]7;file://h/tmp\x18\x07");
        assert_eq!(scanner.current(), None);
    }
}
