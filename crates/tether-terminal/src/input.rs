//! Semantic input out to the byte stream.
//!
//! The upstream engine does not do this: parsing is one direction, and what a
//! key press means on the wire is the other. It depends on terminal state —
//! the same arrow key is `ESC [ A` or `ESC O A` depending on a mode the remote
//! program set — which is why encoding is a method on [`Terminal`] rather than
//! a free function (spec §12).
//!
//! [`Terminal`]: crate::Terminal

use crate::screen::Modes;

/// A key, named by what it is rather than by a scancode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Key {
    /// A character the person typed, already composed: input methods, dead
    /// keys and combining marks are resolved before this point.
    Char(char),
    Enter,
    Tab,
    Backspace,
    Escape,
    Delete,
    Insert,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    /// F1 upwards. Numbers beyond what terminals define encode as nothing.
    Function(u8),
}

/// Which modifiers were held.
///
/// No `command`: terminals do not send it, and a field that encoded to nothing
/// would be a promise we do not keep. On Apple keyboards Option is `alt`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Modifiers {
    pub shift: bool,
    pub alt: bool,
    pub control: bool,
}

impl Modifiers {
    pub const NONE: Self = Self { shift: false, alt: false, control: false };

    pub fn control() -> Self {
        Self { control: true, ..Self::NONE }
    }

    pub fn alt() -> Self {
        Self { alt: true, ..Self::NONE }
    }

    pub fn shift() -> Self {
        Self { shift: true, ..Self::NONE }
    }

    fn is_empty(self) -> bool {
        self == Self::NONE
    }

    /// The `xterm` modifier parameter: a bitfield, offset by one.
    fn parameter(self) -> u8 {
        1 + u8::from(self.shift) + 2 * u8::from(self.alt) + 4 * u8::from(self.control)
    }
}

/// Something the person did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Input {
    Key {
        key: Key,
        modifiers: Modifiers,
    },
    /// Text arriving all at once rather than typed.
    Paste(String),
}

impl Input {
    pub fn key(key: Key) -> Self {
        Self::Key { key, modifiers: Modifiers::NONE }
    }

    pub fn character(c: char) -> Self {
        Self::key(Key::Char(c))
    }
}

/// The marker a program watches for to know a paste ended.
const PASTE_END: &str = "\x1b[201~";

pub(crate) fn encode(input: &Input, modes: Modes) -> Vec<u8> {
    match input {
        Input::Key { key, modifiers } => encode_key(key, *modifiers, modes),
        Input::Paste(text) => encode_paste(text, modes),
    }
}

/// Wraps pasted text so the far side can tell it from typing — but only when
/// the far side asked for that, because a program that did not ask would
/// receive the markers as literal text.
fn encode_paste(text: &str, modes: Modes) -> Vec<u8> {
    if !modes.bracketed_paste {
        return text.as_bytes().to_vec();
    }

    // Pasted content containing the end marker would close the bracket early
    // and let the rest arrive as if it had been typed — which is how a paste
    // becomes command execution. Remove it; there is no legitimate paste that
    // contains its own terminator.
    let safe = text.replace(PASTE_END, "");

    let mut out = Vec::with_capacity(safe.len() + 12);
    out.extend_from_slice(b"\x1b[200~");
    out.extend_from_slice(safe.as_bytes());
    out.extend_from_slice(PASTE_END.as_bytes());
    out
}

fn encode_key(key: &Key, modifiers: Modifiers, modes: Modes) -> Vec<u8> {
    match key {
        Key::Char(c) => encode_char(*c, modifiers),
        Key::Enter => with_alt(b"\r", modifiers),
        Key::Tab if modifiers.shift => b"\x1b[Z".to_vec(),
        Key::Tab => with_alt(b"\t", modifiers),
        // DEL, not BS: this is what every terminal has sent for the key above
        // Return since the 1980s, and `stty erase` assumes it.
        Key::Backspace => with_alt(b"\x7f", modifiers),
        Key::Escape => with_alt(b"\x1b", modifiers),

        Key::Up => cursor_key(b'A', modifiers, modes),
        Key::Down => cursor_key(b'B', modifiers, modes),
        Key::Right => cursor_key(b'C', modifiers, modes),
        Key::Left => cursor_key(b'D', modifiers, modes),
        Key::Home => cursor_key(b'H', modifiers, modes),
        Key::End => cursor_key(b'F', modifiers, modes),

        Key::Insert => tilde_key(2, modifiers),
        Key::Delete => tilde_key(3, modifiers),
        Key::PageUp => tilde_key(5, modifiers),
        Key::PageDown => tilde_key(6, modifiers),

        Key::Function(n) => function_key(*n, modifiers),
    }
}

fn encode_char(c: char, modifiers: Modifiers) -> Vec<u8> {
    let mut bytes = if modifiers.control {
        match control_of(c) {
            Some(byte) => vec![byte],
            // A control chord with no encoding sends the character itself;
            // dropping it would swallow the keystroke silently.
            None => c.to_string().into_bytes(),
        }
    } else {
        c.to_string().into_bytes()
    };

    if modifiers.alt {
        bytes.insert(0, 0x1b);
    }
    bytes
}

/// The control character a chord produces, where one exists.
fn control_of(c: char) -> Option<u8> {
    match c {
        ' ' | '@' => Some(0x00),
        'a'..='z' => Some(c as u8 - b'a' + 1),
        'A'..='Z' => Some(c as u8 - b'A' + 1),
        '[' => Some(0x1b),
        '\\' => Some(0x1c),
        ']' => Some(0x1d),
        '^' => Some(0x1e),
        '_' | '/' => Some(0x1f),
        '?' => Some(0x7f),
        _ => None,
    }
}

fn with_alt(bytes: &[u8], modifiers: Modifiers) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len() + 1);
    if modifiers.alt {
        out.push(0x1b);
    }
    out.extend_from_slice(bytes);
    out
}

/// Arrows and Home/End.
///
/// Application mode is not decoration: a shell's line editor and a full-screen
/// program read different sequences, and sending the wrong one is why arrow
/// keys sometimes print `^[[A` instead of moving.
fn cursor_key(final_byte: u8, modifiers: Modifiers, modes: Modes) -> Vec<u8> {
    if !modifiers.is_empty() {
        // Modified keys are always CSI form, whatever the mode.
        return format!("\x1b[1;{}{}", modifiers.parameter(), final_byte as char).into_bytes();
    }
    if modes.application_cursor_keys {
        vec![0x1b, b'O', final_byte]
    } else {
        vec![0x1b, b'[', final_byte]
    }
}

fn tilde_key(number: u8, modifiers: Modifiers) -> Vec<u8> {
    if modifiers.is_empty() {
        format!("\x1b[{number}~").into_bytes()
    } else {
        format!("\x1b[{number};{}~", modifiers.parameter()).into_bytes()
    }
}

fn function_key(number: u8, modifiers: Modifiers) -> Vec<u8> {
    // F1–F4 are SS3 sequences.
    if let 1..=4 = number {
        let final_byte = b'P' + (number - 1);
        return if modifiers.is_empty() {
            vec![0x1b, b'O', final_byte]
        } else {
            format!("\x1b[1;{}{}", modifiers.parameter(), final_byte as char).into_bytes()
        };
    }

    // F5 upwards are CSI sequences whose numbers skip values, because the
    // keyboards they were defined for did. The gaps are irregular — 23 follows
    // 21, 28 follows 26 — so this is a table, not a formula. A formula here
    // would be a guess that happens to work for F5–F12.
    let tilde = match number {
        5 => 15,
        6 => 17,
        7 => 18,
        8 => 19,
        9 => 20,
        10 => 21,
        11 => 23,
        12 => 24,
        13 => 25,
        14 => 26,
        15 => 28,
        16 => 29,
        17 => 31,
        18 => 32,
        19 => 33,
        20 => 34,
        // Terminals define nothing beyond F20; inventing a sequence would put
        // bytes on the wire that no program expects.
        _ => return Vec::new(),
    };
    tilde_key(tilde, modifiers)
}
