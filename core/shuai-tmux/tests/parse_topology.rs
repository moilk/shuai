use shuai_tmux::cmd::FIELD_SEP;
use shuai_tmux::parse::{
    ParseError, parse_sessions, parse_topology, parse_windows, unescape_output,
};
use shuai_tmux::*;

fn join(fields: &[&str]) -> String {
    fields.join(&FIELD_SEP.to_string())
}

#[allow(clippy::too_many_arguments)]
fn pane_line(sname: &str, wname: &str, wid: &str, pane: &str, title: &str, path: &str) -> String {
    join(&[
        "$0",
        sname,
        "1",
        wid,
        "0",
        wname,
        "1",
        "*",
        pane,
        "0",
        "1",
        "zsh",
        path,
        "123",
        "/dev/ttys001",
        title,
        "80",
        "24",
    ])
}

#[test]
fn unescape() {
    assert_eq!(unescape_output("plain"), "plain");
    assert_eq!(unescape_output(r"a\\b"), r"a\b");
    assert_eq!(unescape_output(r"a\tb\nc"), "a\tb\nc");
    assert_eq!(unescape_output(r"x\037y"), "x\u{1f}y");
    assert_eq!(unescape_output(r"\344\270\255"), "中");
    assert_eq!(unescape_output("中文 é"), "中文 é");
    // lone backslash at the end / unknown escape is kept as-is
    assert_eq!(unescape_output("a\\"), "a\\");
    assert_eq!(unescape_output(r"\q"), r"\q");
}

#[test]
fn parse_real_local_fixture() {
    let t = parse_topology(include_str!("fixtures/local36-listpanes.txt")).unwrap();
    assert_eq!(t.sessions.len(), 1);
    let s = &t.sessions[0];
    assert_eq!(
        (s.id, s.name.as_str(), s.attached),
        (SessionId(0), "main", 0)
    );
    assert_eq!(s.windows.len(), 2);
    let w0 = &s.windows[0];
    assert_eq!(
        (w0.id, w0.index, w0.name.as_str(), w0.active),
        (WindowId(0), 0, "zsh", false)
    );
    assert_eq!(w0.flags, "-");
    assert_eq!(w0.panes.len(), 1);
    assert_eq!(w0.panes[0].id, PaneId(0));
    assert_eq!(w0.panes[0].current_path, "/private/tmp");
    assert_eq!(w0.panes[0].tty, "/dev/ttys002");
    assert_eq!((w0.panes[0].width, w0.panes[0].height), (120, 40));
    let w1 = &s.windows[1];
    assert_eq!(w1.name, "we ird;\"x");
    assert!(w1.active);
    assert_eq!(w1.flags, "*");
    assert_eq!(
        w1.panes.iter().map(|p| p.id).collect::<Vec<_>>(),
        [PaneId(1), PaneId(2)]
    );
    assert_eq!(w1.panes[1].current_command, "env");
    assert!(w1.panes[1].active && !w1.panes[0].active);
}

#[test]
fn parse_real_remote_fixture() {
    let t = parse_topology(include_str!("fixtures/remote36-listpanes.txt")).unwrap();
    assert_eq!(
        t.sessions[0].windows[1].panes[1].current_path,
        "/home/ubuntu"
    );
    assert_eq!(t.sessions[0].windows[1].panes[0].tty, "/dev/pts/1");
}

#[test]
fn hostile_names_roundtrip() {
    // Names as tmux prints them: backslash doubled, control chars octal, others raw.
    let l1 = pane_line(
        "we ird;\"x 中文",
        r"a\\b\037c\nd",
        "@7",
        "%9",
        "title with spaces\tand tab? no: escaped \\t",
        "/p/a b/中",
    );
    let t = parse_topology(&l1).unwrap();
    let s = &t.sessions[0];
    assert_eq!(s.name, "we ird;\"x 中文");
    assert_eq!(s.windows[0].name, "a\\b\u{1f}c\nd");
    assert_eq!(s.windows[0].panes[0].current_path, "/p/a b/中");
}

#[test]
fn panes_group_by_window_in_first_seen_order_and_crlf_ok() {
    let a = pane_line("s", "w1", "@1", "%1", "", "/");
    let b = pane_line("s", "w2", "@2", "%2", "", "/");
    let c = pane_line("s", "w1", "@1", "%3", "", "/");
    let t = parse_topology(&format!("{a}\r\n{b}\r\n{c}\r\n\r\n")).unwrap();
    let w = &t.sessions[0].windows;
    assert_eq!(w.len(), 2);
    assert_eq!(w[0].panes.len(), 2);
    assert_eq!(w[1].id, WindowId(2));
    assert_eq!(parse_topology("").unwrap(), TmuxTopology::default());
}

#[test]
fn parse_errors() {
    assert_eq!(
        parse_topology("a\u{1f}b\u{1f}c"),
        Err(ParseError::FieldCount {
            line: 1,
            expected: 18,
            got: 3
        })
    );
    let bad = pane_line("s", "w", "@x", "%1", "", "/");
    let ok = pane_line("s", "w", "@1", "%1", "", "/");
    match parse_topology(&format!("{ok}\n{bad}")) {
        Err(ParseError::BadField { line: 2, field, .. }) => assert_eq!(field, "window_id"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn parse_sessions_and_windows() {
    let s = parse_sessions(&format!(
        "{}\n{}\n",
        join(&["$0", "main", "1"]),
        join(&["$3", "my\\\\x", "0"])
    ))
    .unwrap();
    assert_eq!(s.len(), 2);
    assert_eq!(
        (s[1].id, s[1].name.as_str(), s[1].attached),
        (SessionId(3), "my\\x", 0)
    );
    assert!(s[0].windows.is_empty());

    let w = parse_windows(&join(&["$3", "@4", "2", "edit", "1", "*Z"])).unwrap();
    assert_eq!(w.len(), 1);
    assert_eq!(w[0].0, SessionId(3));
    assert_eq!(
        (w[0].1.id, w[0].1.index, w[0].1.flags.as_str()),
        (WindowId(4), 2, "*Z")
    );
    assert!(w[0].1.active);
}
