//! What the person did, on its way in.
//!
//! A mirror of `tether-terminal`'s input vocabulary rather than a re-export,
//! because UniFFI needs types it generated and because the boundary should
//! not move every time the engine's enum gains a variant. The translation is
//! dull on purpose: a boundary that reasons is a boundary that drifts.

use tether_core::terminal::{Input, Key, Modifiers};

/// A key, named by what it is rather than by a scancode.
///
/// `Char` carries a `String`, not a character: what a person typed may be a
/// grapheme built from several scalars, and the platform keyboard layer
/// resolved it before we saw it. Splitting that back into a `char` at the
/// boundary would break exactly the input methods people rely on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum KeyPress {
    Char { text: String },
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
    Function { number: u8 },
}

/// Which modifiers were held.
///
/// No `command`: terminals do not send it, and a field that encoded to
/// nothing would be a promise we do not keep. On Apple keyboards, Option is
/// `alt` — a frontend maps its platform's names onto these, and this side
/// stays platform-free (spec §14).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct KeyModifiers {
    pub shift: bool,
    pub alt: bool,
    pub control: bool,
}

/// Something the person did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalInput {
    Key {
        key: KeyPress,
        modifiers: KeyModifiers,
    },
    /// Text arriving all at once rather than typed. Bracketing — and the
    /// stripping that stops a paste from ending its own bracket — happens in
    /// the engine, where the mode that decides it lives.
    Paste {
        text: String,
    },
}

/// What an input turns out to be once translated.
///
/// Two outcomes rather than an `Option`, because "this is not a key press" is
/// not a failure — it is composed text, and it still has to reach the far
/// side. Making the caller infer that from `None` is what previously left the
/// modifiers on such an input silently dropped.
pub enum Resolved {
    /// A key the engine encodes, against the modes the remote program set.
    Encoded(Input),
    /// Text the platform composed, to be sent as itself.
    ///
    /// No bracketing: bracketed paste tells a program that text was *pasted*,
    /// and an input method's output was typed.
    Literal(String),
}

impl TerminalInput {
    /// Translates to the engine's vocabulary.
    ///
    /// Public because which key becomes which sequence is the contract a
    /// frontend depends on, and a mismapped variant is invisible downstream —
    /// nothing can tell `Home` from `End` once the wrong one was chosen.
    pub fn resolve(&self) -> Resolved {
        match self {
            Self::Paste { text } => Resolved::Encoded(Input::Paste(text.clone())),
            Self::Key { key, modifiers } => match key_of(key) {
                Some(key) => Resolved::Encoded(Input::Key {
                    key,
                    modifiers: Modifiers {
                        shift: modifiers.shift,
                        alt: modifiers.alt,
                        control: modifiers.control,
                    },
                }),
                // A grapheme built from several scalars is not a key press —
                // no terminal defines an encoding for "é as one keystroke
                // with Control held", so the modifiers are dropped here
                // rather than used to invent bytes the far side never
                // expects. What remains is the text itself.
                None => Resolved::Literal(text_of(key)),
            },
        }
    }
}

/// The text a key carries, for the keys that carry any.
fn text_of(key: &KeyPress) -> String {
    match key {
        KeyPress::Char { text } => text.clone(),
        _ => String::new(),
    }
}

fn key_of(key: &KeyPress) -> Option<Key> {
    Some(match key {
        KeyPress::Char { text } => {
            let mut scalars = text.chars();
            let first = scalars.next()?;
            // A multi-scalar grapheme is not a key press. A frontend that has
            // one is describing pasted or composed text and should say so.
            if scalars.next().is_some() {
                return None;
            }
            Key::Char(first)
        }
        KeyPress::Enter => Key::Enter,
        KeyPress::Tab => Key::Tab,
        KeyPress::Backspace => Key::Backspace,
        KeyPress::Escape => Key::Escape,
        KeyPress::Delete => Key::Delete,
        KeyPress::Insert => Key::Insert,
        KeyPress::Up => Key::Up,
        KeyPress::Down => Key::Down,
        KeyPress::Left => Key::Left,
        KeyPress::Right => Key::Right,
        KeyPress::Home => Key::Home,
        KeyPress::End => Key::End,
        KeyPress::PageUp => Key::PageUp,
        KeyPress::PageDown => Key::PageDown,
        KeyPress::Function { number } => Key::Function(*number),
    })
}
