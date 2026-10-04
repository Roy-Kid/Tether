//! Recording is an observer: it must not alter VT behavior, even when input
//! is split inside escapes or UTF-8 and the live history buffer is full.
use tether_terminal::{Options, ScreenSize, Scroll, Terminal};

#[test]
fn recording_matches_the_unmodified_engine_for_the_compatibility_corpus() {
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/corpus");
    for name in ["shell", "agent", "vim", "less", "git", "dashboard", "finder", "tmux"] {
        let bytes = std::fs::read(directory.join(format!("{name}.vt"))).unwrap();
        for chunk_size in [1, 97, 4096] {
            let options = Options { scrollback_lines: 20 };
            let mut plain = Terminal::with_options(ScreenSize::new(80, 24), options);
            let mut recorded = Terminal::with_options(ScreenSize::new(80, 24), options);
            recorded.record_history();
            for chunk in bytes.chunks(chunk_size) {
                plain.feed(chunk);
                recorded.feed(chunk);
                recorded.take_history_events();
                assert_eq!(plain.take_replies(), recorded.take_replies(), "{name}");
            }
            assert_eq!(plain.screen(), recorded.screen(), "{name} chunks {chunk_size}");
            assert_eq!(plain.title(), recorded.title());
            plain.scroll(Scroll::Oldest);
            recorded.scroll(Scroll::Oldest);
            assert_eq!(plain.screen(), recorded.screen(), "{name} oldest chunks {chunk_size}");
        }
    }
}
