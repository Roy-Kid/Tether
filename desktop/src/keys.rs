//! A key as GPUI names it, to what the terminal is sent.
//!
//! The rules are the Mac app's (`KeyCaptureMac.input(for:)`): a control
//! chord is built from the base letter, Option is Meta, and Command is the
//! application's. The engine encodes the result against the far side's modes.

use tether_ffi::{KeyModifiers, KeyPress, TerminalInput};

/// The parts of a keystroke the mapping reads. `key` is GPUI's name for the
/// key without modifiers; `key_char` is the text the layout produced with them.
#[derive(Clone, Copy, Debug, Default)]
pub struct Stroke<'a> {
    pub key: &'a str,
    pub key_char: Option<&'a str>,
    pub shift: bool,
    pub alt: bool,
    pub control: bool,
    /// Command on a Mac, Windows on Windows.
    pub platform: bool,
}

/// `None` is a key the terminal does not take: an application shortcut, or
/// a key with no text and no name.
pub fn input(stroke: Stroke<'_>) -> Option<TerminalInput> {
    if stroke.platform {
        return None;
    }
    let modifiers = KeyModifiers { shift: stroke.shift, alt: stroke.alt, control: stroke.control };
    let key = match named(stroke.key) {
        Some(key) => key,
        None => KeyPress::Char { text: text(stroke)? },
    };
    Some(TerminalInput::Key { key, modifiers })
}

fn text(stroke: Stroke<'_>) -> Option<String> {
    let base = match stroke.key {
        "space" => " ",
        other => other,
    };
    // A chord and Option-as-Meta both want the letter, not what the layout made of it.
    let text = if stroke.control || stroke.alt {
        base
    } else {
        stroke.key_char.filter(|text| !text.is_empty()).unwrap_or(base)
    };
    (text.chars().count() == 1 || stroke.key_char == Some(text)).then(|| text.to_owned())
}

fn named(key: &str) -> Option<KeyPress> {
    Some(match key {
        "enter" => KeyPress::Enter,
        "tab" => KeyPress::Tab,
        "backspace" => KeyPress::Backspace,
        "escape" => KeyPress::Escape,
        "delete" => KeyPress::Delete,
        "insert" => KeyPress::Insert,
        "up" => KeyPress::Up,
        "down" => KeyPress::Down,
        "left" => KeyPress::Left,
        "right" => KeyPress::Right,
        "home" => KeyPress::Home,
        "end" => KeyPress::End,
        "pageup" => KeyPress::PageUp,
        "pagedown" => KeyPress::PageDown,
        _ => {
            let number: u8 = key.strip_prefix('f')?.parse().ok()?;
            if !(1..=20).contains(&number) {
                return None;
            }
            KeyPress::Function { number }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(stroke: Stroke<'_>) -> (KeyPress, KeyModifiers) {
        match input(stroke) {
            Some(TerminalInput::Key { key, modifiers }) => (key, modifiers),
            other => panic!("{other:?}"),
        }
    }

    fn char(text: &str) -> KeyPress {
        KeyPress::Char { text: text.to_owned() }
    }

    #[test]
    fn typed_text_is_what_the_layout_produced() {
        let stroke = Stroke { key: "a", key_char: Some("A"), shift: true, ..Default::default() };
        assert_eq!(key(stroke).0, char("A"));
        let stroke = Stroke { key: "space", key_char: Some(" "), ..Default::default() };
        assert_eq!(key(stroke).0, char(" "));
    }

    #[test]
    fn a_control_chord_is_the_base_letter() {
        let stroke =
            Stroke { key: "c", key_char: Some("\u{3}"), control: true, ..Default::default() };
        let (press, modifiers) = key(stroke);
        assert_eq!(press, char("c"));
        assert!(modifiers.control);
    }

    #[test]
    fn option_is_meta() {
        let stroke = Stroke { key: "b", key_char: Some("∫"), alt: true, ..Default::default() };
        let (press, modifiers) = key(stroke);
        assert_eq!(press, char("b"));
        assert!(modifiers.alt);
    }

    #[test]
    fn named_keys_keep_their_modifiers() {
        let stroke = Stroke { key: "left", shift: true, ..Default::default() };
        assert_eq!(
            key(stroke),
            (KeyPress::Left, KeyModifiers { shift: true, ..Default::default() })
        );
        assert_eq!(
            key(Stroke { key: "f12", ..Default::default() }).0,
            KeyPress::Function { number: 12 }
        );
        assert_eq!(key(Stroke { key: "enter", ..Default::default() }).0, KeyPress::Enter);
    }

    #[test]
    fn command_belongs_to_the_application() {
        assert!(
            input(Stroke { key: "c", key_char: Some("c"), platform: true, ..Default::default() })
                .is_none()
        );
    }

    #[test]
    fn a_nameless_key_without_text_is_dropped() {
        assert!(input(Stroke { key: "f99", ..Default::default() }).is_none());
        assert!(input(Stroke { key: "capslock", ..Default::default() }).is_none());
    }

    #[test]
    fn composed_text_longer_than_a_character_passes() {
        let stroke = Stroke { key: "e", key_char: Some("é"), ..Default::default() };
        assert_eq!(key(stroke).0, char("é"));
        let stroke = Stroke { key: "1", key_char: Some("👍🏽"), ..Default::default() };
        assert_eq!(key(stroke).0, char("👍🏽"));
    }
}
