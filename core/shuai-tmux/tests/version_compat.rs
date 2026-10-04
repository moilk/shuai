//! `-F` output captured from real tmux 3.2, 3.3a, 3.4, 3.5a and 3.6a (synthetic names).
//! tmux 3.4/3.5 print the `\x1f` separator escaped as the four characters `\037`;
//! the others print it raw. Field values always have `\` doubled and control
//! characters escaped, so an unescaped `\037` can only be a separator.

use shuai_tmux::parse::{parse_topology, split_fields};

const WINDOW_NAME: &str = "we\\037ird\ttab\\\\bs";

fn fixture(v: &str) -> String {
    std::fs::read_to_string(format!(
        "{}/tests/fixtures/listpanes-tmux{v}.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

#[test]
fn every_version_parses_to_the_same_topology() {
    for v in ["3.2", "3.3a", "3.4", "3.5a", "3.6a"] {
        let t = parse_topology(&fixture(v)).unwrap_or_else(|e| panic!("tmux {v}: {e:?}"));
        let s = &t.sessions[0];
        assert_eq!(s.name, "demo", "tmux {v}");
        let w = &s.windows[0];
        assert_eq!(w.name, WINDOW_NAME, "tmux {v}");
        assert_eq!(w.panes.len(), 2, "tmux {v}");
        assert_eq!(w.panes[0].current_path, "/private/tmp", "tmux {v}");
    }
}

#[test]
fn raw_separator_splits() {
    assert_eq!(split_fields("a\u{1f}b\u{1f}c"), vec!["a", "b", "c"]);
}

#[test]
fn escaped_separator_splits_when_no_raw_separator_is_present() {
    assert_eq!(split_fields("a\\037b\\037c"), vec!["a", "b", "c"]);
}

#[test]
fn escaped_backslash_before_037_is_field_text_not_a_separator() {
    // `\\037` = literal backslash + "037" inside a value
    assert_eq!(split_fields("x\\\\037y\\037z"), vec!["x\\\\037y", "z"]);
    // three backslashes: escaped backslash, then a real separator
    assert_eq!(split_fields("x\\\\\\037z"), vec!["x\\\\", "z"]);
}

#[test]
fn raw_separator_wins_over_escaped_text() {
    // tmux 3.6: a value containing a real 0x1f is printed as `\037`
    assert_eq!(split_fields("a\\037b\u{1f}c"), vec!["a\\037b", "c"]);
}

#[test]
fn no_separator_is_one_field() {
    assert_eq!(split_fields("plain"), vec!["plain"]);
    assert_eq!(split_fields(""), vec![""]);
}
