//! What a key press becomes on its way in.
//!
//! The translation is deliberately dull, and dull code is where a mismapped
//! variant hides: nothing downstream can tell `Home` from `End` once the
//! wrong one has been chosen. So every key is checked against the bytes a
//! terminal actually sends, through a real engine rather than a mock.

use tether_core::terminal::{ScreenSize, Terminal};
use tether_ffi::{KeyModifiers, KeyPress, Resolved, TerminalInput};

/// Encodes through a real terminal, because that is the only thing that knows
/// what a key means — the modes the remote program set decide it.
fn bytes(input: TerminalInput) -> Vec<u8> {
    let terminal = Terminal::new(ScreenSize::new(80, 24));
    match input.resolve() {
        Resolved::Encoded(core) => terminal.encode(&core),
        Resolved::Literal(text) => text.into_bytes(),
    }
}

fn key(key: KeyPress) -> Vec<u8> {
    bytes(TerminalInput::Key { key, modifiers: KeyModifiers::default() })
}

fn chord(key: KeyPress, modifiers: KeyModifiers) -> Vec<u8> {
    bytes(TerminalInput::Key { key, modifiers })
}

#[test]
fn ordinary_text_goes_out_as_itself() {
    assert_eq!(key(KeyPress::Char { text: "a".into() }), b"a");
    assert_eq!(key(KeyPress::Char { text: "中".into() }), "中".as_bytes());
}

/// Every named key must reach the engine as the key it names. A table, not a
/// loop, because the point is to catch a variant wired to its neighbour.
#[test]
fn every_named_key_maps_to_the_sequence_its_name_promises() {
    assert_eq!(key(KeyPress::Enter), b"\r");
    assert_eq!(key(KeyPress::Tab), b"\t");
    // DEL, not backspace: what the key above Return has sent since the 1980s.
    assert_eq!(key(KeyPress::Backspace), b"\x7f");
    assert_eq!(key(KeyPress::Escape), b"\x1b");

    assert_eq!(key(KeyPress::Up), b"\x1b[A");
    assert_eq!(key(KeyPress::Down), b"\x1b[B");
    assert_eq!(key(KeyPress::Right), b"\x1b[C");
    assert_eq!(key(KeyPress::Left), b"\x1b[D");
    assert_eq!(key(KeyPress::Home), b"\x1b[H");
    assert_eq!(key(KeyPress::End), b"\x1b[F");

    assert_eq!(key(KeyPress::Insert), b"\x1b[2~");
    assert_eq!(key(KeyPress::Delete), b"\x1b[3~");
    assert_eq!(key(KeyPress::PageUp), b"\x1b[5~");
    assert_eq!(key(KeyPress::PageDown), b"\x1b[6~");

    assert_eq!(key(KeyPress::Function { number: 1 }), b"\x1bOP");
    assert_eq!(key(KeyPress::Function { number: 5 }), b"\x1b[15~");
    assert_eq!(key(KeyPress::Function { number: 12 }), b"\x1b[24~");
}

#[test]
fn modifiers_reach_the_engine_rather_than_being_dropped() {
    let control = KeyModifiers { shift: false, alt: false, control: true };
    assert_eq!(chord(KeyPress::Char { text: "c".into() }, control), b"\x03");

    let alt = KeyModifiers { shift: false, alt: true, control: false };
    assert_eq!(chord(KeyPress::Char { text: "b".into() }, alt), b"\x1bb");

    let shift = KeyModifiers { shift: true, alt: false, control: false };
    assert_eq!(chord(KeyPress::Tab, shift), b"\x1b[Z");

    // A modified arrow is CSI form whatever the cursor mode, with the
    // modifier as a parameter.
    assert_eq!(chord(KeyPress::Up, control), b"\x1b[1;5A");
}

/// A key no terminal defines sends nothing, rather than bytes invented to
/// fill the gap.
#[test]
fn a_key_no_terminal_defines_sends_nothing() {
    assert!(key(KeyPress::Function { number: 21 }).is_empty());
    assert!(key(KeyPress::Char { text: String::new() }).is_empty());
}

/// Composed text is not a key press. It still has to arrive, so it is sent as
/// itself — and not bracketed, because bracketing would tell the far side it
/// was pasted when it was typed.
#[test]
fn composed_text_is_sent_as_text_rather_than_encoded_as_a_key() {
    // A family emoji is one grapheme built from five scalars; no terminal
    // defines a keystroke for it.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    assert_eq!(key(KeyPress::Char { text: family.into() }), family.as_bytes());

    // Held modifiers have no encoding for such a thing, and must not change
    // what is sent.
    let control = KeyModifiers { shift: false, alt: false, control: true };
    assert_eq!(chord(KeyPress::Char { text: family.into() }, control), family.as_bytes());
}

/// A single scalar is a key press even when it is not ASCII, so a control
/// chord on it still works.
#[test]
fn a_single_scalar_is_still_a_key_press() {
    let control = KeyModifiers { shift: false, alt: false, control: true };
    // `é` as one scalar has no control encoding, so the character survives
    // rather than being swallowed.
    assert_eq!(chord(KeyPress::Char { text: "\u{00e9}".into() }, control), "é".as_bytes());
}

#[test]
fn a_paste_is_plain_text_until_the_far_side_asks_for_brackets() {
    assert_eq!(bytes(TerminalInput::Paste { text: "hello".into() }), b"hello");

    let mut terminal = Terminal::new(ScreenSize::new(80, 24));
    terminal.feed(b"\x1b[?2004h");
    let Resolved::Encoded(core) = TerminalInput::Paste { text: "hello".into() }.resolve() else {
        panic!("a paste is always encodable");
    };
    assert_eq!(terminal.encode(&core), b"\x1b[200~hello\x1b[201~");
}
