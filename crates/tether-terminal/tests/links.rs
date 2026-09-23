//! What is under a point on the screen, when it names somewhere.
//!
//! The case this exists for: an agent prints `Wrote src/plot.png`, and a
//! person points at it. The terminal answers with the text it would open and
//! where on the screen that text is, so a frontend can underline it. Whether
//! the file exists is the frontend's question — it is the one holding the
//! connection — so this is shape, not truth, and errs toward answering.

use tether_terminal::{LinkTarget, Position, ScreenSize, Scroll, Terminal};

fn terminal(columns: u16, rows: u16, bytes: &str) -> Terminal {
    let mut terminal = Terminal::new(ScreenSize::new(columns, rows));
    terminal.feed(bytes.as_bytes());
    terminal
}

fn path_at(
    terminal: &Terminal,
    row: u16,
    column: u16,
) -> Option<(String, Option<u32>, Option<u32>)> {
    match terminal.link_at(Position::new(row, column))?.target {
        LinkTarget::Path { path, line, column } => Some((path, line, column)),
        other => panic!("expected a path, got {other:?}"),
    }
}

#[test]
fn an_absolute_path_is_found_from_any_of_its_characters() {
    let terminal = terminal(80, 4, "Wrote /home/ada/runs/plot.png\r\n");
    for column in 6..29 {
        assert_eq!(
            path_at(&terminal, 0, column),
            Some(("/home/ada/runs/plot.png".to_owned(), None, None)),
            "column {column}"
        );
    }
    assert_eq!(terminal.link_at(Position::new(0, 5)), None, "the space before it");
    assert_eq!(terminal.link_at(Position::new(0, 2)), None, "an ordinary word");
}

#[test]
fn the_link_says_where_it_is_so_it_can_be_underlined() {
    let terminal = terminal(80, 4, "  see src/lib.rs now\r\n");
    let link = terminal.link_at(Position::new(0, 8)).expect("a link");
    assert_eq!(link.text, "src/lib.rs");
    assert_eq!(link.spans.len(), 1);
    assert_eq!((link.spans[0].row, link.spans[0].start, link.spans[0].end), (0, 6, 16));
}

#[test]
fn a_line_and_column_suffix_is_kept_apart_from_the_path() {
    let terminal = terminal(80, 4, "error at src/main.rs:12:5 here\r\nand crates/a.rs:7\r\n");
    assert_eq!(path_at(&terminal, 0, 12), Some(("src/main.rs".to_owned(), Some(12), Some(5))));
    assert_eq!(path_at(&terminal, 0, 22), Some(("src/main.rs".to_owned(), Some(12), Some(5))));
    assert_eq!(path_at(&terminal, 1, 6), Some(("crates/a.rs".to_owned(), Some(7), None)));
}

#[test]
fn quotes_mentions_and_sentence_punctuation_are_not_part_of_it() {
    let terminal = terminal(
        80,
        6,
        concat!(
            "Updated `docs/report.pdf`.\r\n",
            "Look at @src/app.rs, then \"~/notes/todo.md\".\r\n",
            "See [the figure](figures/fig1.svg) above.\r\n",
            "(output/result.csv)\r\n",
        ),
    );
    assert_eq!(path_at(&terminal, 0, 12).unwrap().0, "docs/report.pdf");
    assert_eq!(path_at(&terminal, 1, 10).unwrap().0, "src/app.rs");
    assert_eq!(path_at(&terminal, 1, 30).unwrap().0, "~/notes/todo.md");
    assert_eq!(path_at(&terminal, 2, 22).unwrap().0, "figures/fig1.svg");
    assert_eq!(path_at(&terminal, 3, 5).unwrap().0, "output/result.csv");
}

#[test]
fn a_bare_file_name_needs_an_extension_and_a_number_is_not_one() {
    let terminal = terminal(80, 4, "wrote plot.png, pi is 3.14, v1.2.3 ok and/or\r\n");
    assert_eq!(path_at(&terminal, 0, 8).unwrap().0, "plot.png");
    assert_eq!(terminal.link_at(Position::new(0, 22)), None, "3.14");
    assert_eq!(terminal.link_at(Position::new(0, 29)), None, "v1.2.3");
}

#[test]
fn a_path_the_screen_wrapped_is_one_path() {
    // Twenty columns: the path runs off the first row onto the second.
    let terminal = terminal(20, 4, "out /data/experiments/run-42/energy.dat\r\n");
    let expected = "/data/experiments/run-42/energy.dat".to_owned();
    assert_eq!(path_at(&terminal, 0, 10).unwrap().0, expected);
    assert_eq!(path_at(&terminal, 1, 3).unwrap().0, expected);
    let link = terminal.link_at(Position::new(1, 3)).unwrap();
    let spans: Vec<(u16, u16, u16)> =
        link.spans.iter().map(|span| (span.row, span.start, span.end)).collect();
    assert_eq!(spans, [(0, 4, 20), (1, 0, 19)]);
}

#[test]
fn a_line_that_merely_ends_at_the_edge_is_not_joined_to_the_next() {
    // Exactly twenty characters, then a newline: two lines, not one.
    let terminal = terminal(20, 4, "aaaaaaaaaa/bbbbbbbbb\r\nccc/ddd.txt\r\n");
    assert_eq!(path_at(&terminal, 0, 3).unwrap().0, "aaaaaaaaaa/bbbbbbbbb");
    assert_eq!(path_at(&terminal, 1, 3).unwrap().0, "ccc/ddd.txt");
}

#[test]
fn columns_are_screen_columns_even_after_wide_characters() {
    // Each CJK character takes two columns; the path starts at column 9.
    let terminal = terminal(80, 4, "写入了： /tmp/结果.png\r\n");
    let link = terminal.link_at(Position::new(0, 12)).expect("a link");
    assert_eq!(link.text, "/tmp/结果.png");
    assert_eq!((link.spans[0].start, link.spans[0].end), (9, 22));
    assert_eq!(terminal.link_at(Position::new(0, 2)), None);
}

#[test]
fn a_web_address_is_a_url_not_a_path() {
    let terminal = terminal(80, 4, "docs at https://example.org/a/b?c=1.\r\n");
    let link = terminal.link_at(Position::new(0, 12)).expect("a link");
    assert_eq!(link.target, LinkTarget::Url("https://example.org/a/b?c=1".to_owned()));
}

#[test]
fn a_hyperlink_the_program_attached_wins_over_the_text() {
    let terminal = terminal(
        80,
        4,
        "\x1b]8;;file://lab/home/ada/report.pdf\x1b\\the report\x1b]8;;\x1b\\ is done\r\n",
    );
    let link = terminal.link_at(Position::new(0, 4)).expect("a link");
    assert_eq!(link.target, LinkTarget::Hyperlink("file://lab/home/ada/report.pdf".to_owned()));
    assert_eq!(link.text, "the report");
    assert_eq!((link.spans[0].start, link.spans[0].end), (0, 10));
    assert_eq!(terminal.link_at(Position::new(0, 12)), None, "past the link");
}

#[test]
fn a_link_in_history_is_found_where_it_is_drawn() {
    let mut terminal = terminal(40, 3, "first /tmp/a.log\r\n");
    terminal.feed(b"x\r\ny\r\nz\r\nw\r\n");
    terminal.scroll(Scroll::Oldest);
    assert_eq!(path_at(&terminal, 0, 8).unwrap().0, "/tmp/a.log");
}

#[test]
fn outside_the_screen_is_nothing() {
    let terminal = terminal(10, 2, "/tmp/a.txt");
    assert_eq!(terminal.link_at(Position::new(5, 0)), None);
    assert_eq!(terminal.link_at(Position::new(0, 50)), None);
}

#[test]
fn the_working_directory_is_what_the_shell_last_reported() {
    let mut terminal = Terminal::new(ScreenSize::new(80, 4));
    assert_eq!(terminal.working_directory(), None);

    terminal.feed(b"\x1b]7;file://lab.example/home/ada/My%20Runs\x07$ ");
    assert_eq!(terminal.working_directory(), Some("/home/ada/My Runs"));

    // Split anywhere, terminated by ST rather than BEL.
    terminal.feed(b"\x1b]7;file://lab/ho");
    terminal.feed(b"me/ada/src\x1b");
    terminal.feed(b"\\");
    assert_eq!(terminal.working_directory(), Some("/home/ada/src"));

    // iTerm's spelling.
    terminal.feed(b"\x1b]1337;CurrentDir=/srv/data\x07");
    assert_eq!(terminal.working_directory(), Some("/srv/data"));

    // Nothing on screen came from any of it.
    assert_eq!(terminal.screen().row_text(0).trim(), "$");
}

#[test]
fn a_working_directory_report_that_is_not_one_is_ignored() {
    let mut terminal = Terminal::new(ScreenSize::new(80, 4));
    terminal.feed(b"\x1b]7;file://lab/home/ada\x07");
    terminal.feed(b"\x1b]7;http://evil/\x07");
    terminal.feed(b"\x1b]7;relative/path\x07");
    let mut endless = b"\x1b]7;file://lab/".to_vec();
    endless.extend(std::iter::repeat_n(b'a', 64 * 1024));
    endless.push(0x07);
    terminal.feed(&endless);
    assert_eq!(terminal.working_directory(), Some("/home/ada"));
}
