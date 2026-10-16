//! Semantic input out to bytes.

use tether_terminal::{Input, Key, Modifiers, PointerButton, PointerPhase, ScreenSize, Terminal};

fn terminal() -> Terminal {
    Terminal::new(ScreenSize::new(80, 24))
}

#[test]
fn wheel_follows_mouse_modes_and_uses_one_based_coordinates() {
    let mut term = terminal();
    assert_eq!(term.encode_wheel(-1, 2, 4), None);
    term.feed(b"\x1b[?1000h\x1b[?1006h");
    assert_eq!(term.encode_wheel(-1, 2, 4).unwrap(), b"\x1b[<64;5;3M");
    assert_eq!(term.encode_wheel(2, 2, 4).unwrap(), b"\x1b[<65;5;3M\x1b[<65;5;3M");
    assert_eq!(term.encode_wheel(0, 0, 0).unwrap(), b"");
    assert_eq!(term.encode_wheel(-1, u16::MAX, u16::MAX).unwrap(), b"\x1b[<64;80;24M");
    term.feed(b"\x1b[?1006l");
    assert_eq!(term.encode_wheel(-1, 2, 4).unwrap(), vec![27, b'[', b'M', 96, 37, 35]);
    term.feed(b"\x1b[?1000l");
    assert_eq!(term.encode_wheel(-1, 2, 4), None);
}

fn encoded(input: Input) -> Vec<u8> {
    terminal().encode(&input)
}

fn key(key: Key, modifiers: Modifiers) -> Vec<u8> {
    encoded(Input::Key { key, modifiers })
}

#[test]
fn plain_characters_go_out_as_themselves() {
    assert_eq!(encoded(Input::character('a')), b"a");
    assert_eq!(encoded(Input::character('中')), "中".as_bytes());
}

#[test]
fn control_chords_become_control_characters() {
    for letter in b'a'..=b'z' {
        assert_eq!(key(Key::Char(letter as char), Modifiers::control()), vec![letter - b'a' + 1]);
    }
    assert_eq!(key(Key::Char('c'), Modifiers::control()), vec![0x03]);
    assert_eq!(key(Key::Char('C'), Modifiers::control()), vec![0x03], "case does not matter");
    assert_eq!(key(Key::Char('d'), Modifiers::control()), vec![0x04]);
    assert_eq!(key(Key::Char(' '), Modifiers::control()), vec![0x00]);
    assert_eq!(key(Key::Char('['), Modifiers::control()), vec![0x1b]);
}

#[test]
fn unix_navigation_chords_remain_distinct_from_arrow_sequences() {
    let mut term = terminal();
    // Even application cursor mode must not turn Control letters into arrows:
    // the shell or editor owns the meaning of these bytes.
    for mode in [b"\x1b[?1l", b"\x1b[?1h"] {
        term.feed(mode);
        for (letter, byte) in [('p', 0x10), ('n', 0x0e), ('f', 0x06), ('b', 0x02)] {
            assert_eq!(
                term.encode(&Input::Key {
                    key: Key::Char(letter),
                    modifiers: Modifiers::control()
                }),
                vec![byte]
            );
        }
    }
}

/// A chord with no defined control character must still send the keystroke.
/// Swallowing it would lose input with no error anywhere.
#[test]
fn an_undefined_control_chord_sends_the_character() {
    assert_eq!(key(Key::Char('1'), Modifiers::control()), b"1");
}

#[test]
fn alt_prefixes_an_escape() {
    assert_eq!(key(Key::Char('b'), Modifiers::alt()), vec![0x1b, b'b']);
    assert_eq!(key(Key::Backspace, Modifiers::alt()), vec![0x1b, 0x7f]);
}

/// The key above Return sends DEL, not BS. Every terminal has done this for
/// forty years and `stty erase` assumes it.
#[test]
fn backspace_sends_delete() {
    assert_eq!(key(Key::Backspace, Modifiers::NONE), vec![0x7f]);
}

#[test]
fn shift_tab_is_a_back_tab() {
    assert_eq!(key(Key::Tab, Modifiers::NONE), b"\t");
    assert_eq!(key(Key::Tab, Modifiers::shift()), b"\x1b[Z");
}

/// The mode the remote program set decides the encoding. Sending the wrong
/// form is why arrow keys sometimes print `^[[A` instead of moving.
#[test]
fn arrow_keys_follow_the_application_cursor_mode() {
    let mut term = terminal();
    assert_eq!(term.encode(&Input::key(Key::Up)), b"\x1b[A");

    term.feed(b"\x1b[?1h");
    assert_eq!(term.encode(&Input::key(Key::Up)), b"\x1bOA");

    term.feed(b"\x1b[?1l");
    assert_eq!(term.encode(&Input::key(Key::Up)), b"\x1b[A");
}

#[test]
fn modified_arrows_are_always_csi_form() {
    let mut term = terminal();
    term.feed(b"\x1b[?1h");

    let modifiers = Modifiers { shift: false, alt: false, control: true };
    assert_eq!(
        term.encode(&Input::Key { key: Key::Right, modifiers }),
        b"\x1b[1;5C",
        "a modified key leaves application mode behind"
    );
}

#[test]
fn the_modifier_parameter_is_a_bitfield_offset_by_one() {
    let shift_alt = Modifiers { shift: true, alt: true, control: false };
    assert_eq!(key(Key::Left, shift_alt), b"\x1b[1;4D");

    let all = Modifiers { shift: true, alt: true, control: true };
    assert_eq!(key(Key::Left, all), b"\x1b[1;8D");
}

#[test]
fn navigation_keys_use_their_historical_numbers() {
    assert_eq!(key(Key::Insert, Modifiers::NONE), b"\x1b[2~");
    assert_eq!(key(Key::Delete, Modifiers::NONE), b"\x1b[3~");
    assert_eq!(key(Key::PageUp, Modifiers::NONE), b"\x1b[5~");
    assert_eq!(key(Key::PageDown, Modifiers::NONE), b"\x1b[6~");
}

/// The gaps are irregular on purpose: 22 and 27 are not function keys.
#[test]
fn function_keys_skip_the_numbers_terminals_skip() {
    assert_eq!(key(Key::Function(1), Modifiers::NONE), b"\x1bOP");
    assert_eq!(key(Key::Function(4), Modifiers::NONE), b"\x1bOS");
    assert_eq!(key(Key::Function(5), Modifiers::NONE), b"\x1b[15~");
    assert_eq!(key(Key::Function(6), Modifiers::NONE), b"\x1b[17~");
    assert_eq!(key(Key::Function(10), Modifiers::NONE), b"\x1b[21~");
    assert_eq!(key(Key::Function(11), Modifiers::NONE), b"\x1b[23~");
    assert_eq!(key(Key::Function(14), Modifiers::NONE), b"\x1b[26~");
    assert_eq!(key(Key::Function(15), Modifiers::NONE), b"\x1b[28~");
    assert_eq!(key(Key::Function(17), Modifiers::NONE), b"\x1b[31~");
    assert_eq!(key(Key::Function(20), Modifiers::NONE), b"\x1b[34~");
}

/// Nothing is defined past F20; inventing a sequence would put bytes on the
/// wire that no program expects.
#[test]
fn undefined_function_keys_send_nothing() {
    assert!(key(Key::Function(21), Modifiers::NONE).is_empty());
}

#[test]
fn a_paste_is_plain_text_until_the_far_side_asks_for_brackets() {
    let mut term = terminal();
    assert_eq!(term.encode(&Input::Paste("ls\n".into())), b"ls\n");

    term.feed(b"\x1b[?2004h");
    assert_eq!(term.encode(&Input::Paste("ls\n".into())), b"\x1b[200~ls\n\x1b[201~");
}

/// Pasted text containing the end marker would close the bracket early and
/// let the rest arrive as if it had been typed — which is how a paste becomes
/// command execution.
#[test]
fn a_paste_cannot_smuggle_its_own_terminator() {
    let mut term = terminal();
    term.feed(b"\x1b[?2004h");

    let hostile = "harmless\x1b[201~rm -rf /\n";
    let encoded = term.encode(&Input::Paste(hostile.into()));
    let text = String::from_utf8(encoded).unwrap();

    assert_eq!(text.matches("\x1b[201~").count(), 1, "exactly one terminator, ours");
    assert!(text.ends_with("\x1b[201~"));
    assert!(text.contains("rm -rf /"), "the text is still delivered, just not as typing");
}

fn pointer(
    term: &Terminal,
    button: PointerButton,
    phase: PointerPhase,
    column: u16,
    row: u16,
) -> Vec<u8> {
    term.encode(&Input::Pointer { button, phase, column, row, modifiers: Modifiers::NONE })
}

/// Nothing is sent until a program asks. A click then still selects text here.
#[test]
fn mouse_events_are_silent_until_tracking_is_on() {
    let term = terminal();
    assert!(pointer(&term, PointerButton::Left, PointerPhase::Press, 0, 0).is_empty());
}

/// Normal tracking, one byte per value plus 32. Cell (0, 0) is protocol (1, 1).
#[test]
fn a_click_is_the_normal_mouse_protocol() {
    let mut term = terminal();
    term.feed(b"\x1b[?1000h");

    assert_eq!(pointer(&term, PointerButton::Left, PointerPhase::Press, 0, 0), b"\x1b[M !!");
    assert_eq!(pointer(&term, PointerButton::Left, PointerPhase::Release, 0, 0), b"\x1b[M#!!");
    assert!(
        pointer(&term, PointerButton::Left, PointerPhase::Move, 1, 0).is_empty(),
        "click tracking does not report motion"
    );
}

#[test]
fn sgr_tracking_names_the_button_and_the_cell() {
    let mut term = terminal();
    term.feed(b"\x1b[?1000h\x1b[?1006h");

    assert_eq!(pointer(&term, PointerButton::Left, PointerPhase::Press, 2, 3), b"\x1b[<0;3;4M");
    assert_eq!(pointer(&term, PointerButton::Left, PointerPhase::Release, 2, 3), b"\x1b[<0;3;4m");
    assert_eq!(pointer(&term, PointerButton::WheelUp, PointerPhase::Press, 0, 0), b"\x1b[<64;1;1M");
    assert!(pointer(&term, PointerButton::WheelUp, PointerPhase::Release, 0, 0).is_empty());
}

#[test]
fn drag_and_any_motion_are_different_modes() {
    let mut term = terminal();
    term.feed(b"\x1b[?1002h\x1b[?1006h");
    assert!(pointer(&term, PointerButton::None, PointerPhase::Move, 0, 0).is_empty());
    assert_eq!(pointer(&term, PointerButton::Left, PointerPhase::Move, 0, 0), b"\x1b[<32;1;1M");

    term.feed(b"\x1b[?1003h");
    assert_eq!(pointer(&term, PointerButton::None, PointerPhase::Move, 4, 5), b"\x1b[<35;5;6M");
}

/// The single-byte protocol stops at 223. A wider screen still reports a cell
/// rather than a byte that wrapped.
#[test]
fn the_normal_protocol_clamps_a_wide_screen() {
    let mut term = terminal();
    term.feed(b"\x1b[?1000h");
    let encoded = pointer(&term, PointerButton::Left, PointerPhase::Press, 400, 0);
    assert_eq!(encoded.len(), 6);
    assert_eq!(encoded[4], 255, "column 223, plus the 32 the protocol adds");
}
