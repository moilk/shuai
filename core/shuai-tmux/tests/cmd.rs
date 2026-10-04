use shuai_tmux::cmd::{self, FIELD_SEP, PANE_FORMAT, SESSION_FORMAT, WINDOW_FORMAT};
use shuai_tmux::quote::{escape_format, shell_quote, tmux_quote};
use shuai_tmux::{Direction, PaneId, SessionId, Target, WindowId};

const NASTY: &[&str] = &[
    "plain",
    "",
    "a b",
    "it's",
    "''",
    "\"dq\"",
    "a;b",
    "a; rm -rf /",
    "$HOME",
    "$(id)",
    "`id`",
    "back\\slash",
    "\\",
    "new\nline",
    "tab\tx",
    "\u{1f}sep",
    "中文 名字",
    "emoji 🚀",
    "~/x",
    "#{pane_id}",
    "a&b|c>d<e",
    "*?[x]",
    "-leading-dash",
    "%1",
    "@2",
    "$1",
    "{brace}",
    "!bang",
    "\u{7f}del",
];

/// Minimal POSIX-ish unquoter: handles '...', "..." (with \ escapes of $`"\), bare backslash.
fn sh_unquote(s: &str) -> Vec<String> {
    let cs: Vec<char> = s.chars().collect();
    let mut out = vec![];
    let mut cur = String::new();
    let mut have = false;
    let mut i = 0;
    while i < cs.len() {
        match cs[i] {
            ' ' => {
                if have {
                    out.push(std::mem::take(&mut cur));
                    have = false;
                }
            }
            '\'' => {
                have = true;
                i += 1;
                while cs[i] != '\'' {
                    cur.push(cs[i]);
                    i += 1;
                }
            }
            '\\' => {
                have = true;
                i += 1;
                cur.push(cs[i]);
            }
            '"' | '$' | '`' | ';' | '&' | '|' | '<' | '>' | '(' | ')' | '*' | '?' | '[' | '#'
            | '~' | '!' | '{' | '\n' | '\t' => {
                panic!("unquoted metacharacter {:?} in {s:?}", cs[i])
            }
            c => {
                have = true;
                cur.push(c);
            }
        }
        i += 1;
    }
    if have {
        out.push(cur);
    }
    out
}

/// Model of tmux's command parser for one line: words split on spaces, `'..'`, `".."` with
/// `\\ \" \$ \n \t \ooo` escapes, bare backslash escapes. Panics on unquoted `;`/`$`/`#`.
fn tmux_unquote(s: &str) -> Vec<String> {
    let b = s.as_bytes();
    let mut out = vec![];
    let mut cur: Vec<u8> = vec![];
    let mut have = false;
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b' ' => {
                if have {
                    out.push(String::from_utf8(std::mem::take(&mut cur)).unwrap());
                    have = false;
                }
            }
            b'"' => {
                have = true;
                i += 1;
                while b[i] != b'"' {
                    if b[i] == b'\\' {
                        i += 1;
                        match b[i] {
                            b'n' => cur.push(b'\n'),
                            b't' => cur.push(b'\t'),
                            b'r' => cur.push(b'\r'),
                            b'0'..=b'7' => {
                                let v = u8::from_str_radix(&s[i..i + 3], 8).unwrap();
                                cur.push(v);
                                i += 2;
                            }
                            c => cur.push(c),
                        }
                    } else {
                        assert!(b[i] != b'$', "unescaped $ in dquote: {s:?}");
                        cur.push(b[i]);
                    }
                    i += 1;
                }
            }
            b'\'' => {
                have = true;
                i += 1;
                while b[i] != b'\'' {
                    cur.push(b[i]);
                    i += 1;
                }
            }
            b'\\' => {
                have = true;
                i += 1;
                cur.push(b[i]);
            }
            b';' | b'$' | b'#' | b'~' | b'\n' | b'{' | b'}' => {
                panic!("unquoted metacharacter {:?} in {s:?}", b[i] as char)
            }
            c => {
                have = true;
                cur.push(c);
            }
        }
        i += 1;
    }
    if have {
        out.push(String::from_utf8(cur).unwrap());
    }
    out
}

#[test]
fn shell_quote_simple() {
    assert_eq!(shell_quote("abc"), "abc");
    assert_eq!(shell_quote("/home/a-b_c.d"), "/home/a-b_c.d");
    assert_eq!(shell_quote(""), "''");
    assert_eq!(shell_quote("a b"), "'a b'");
    assert_eq!(shell_quote("it's"), r"'it'\''s'");
    assert_eq!(shell_quote("=x"), "'=x'");
    assert_eq!(shell_quote("中文"), "'中文'");
}

#[test]
fn shell_quote_roundtrips_adversarial() {
    for s in NASTY {
        let q = shell_quote(s);
        assert_eq!(
            sh_unquote(&q),
            vec![s.to_string()],
            "input {s:?} quoted {q:?}"
        );
    }
}

#[test]
fn tmux_quote_simple() {
    assert_eq!(tmux_quote("abc"), "abc");
    assert_eq!(tmux_quote(""), "\"\"");
    assert_eq!(tmux_quote("$0"), "\"\\$0\"");
    assert_eq!(tmux_quote("a;b"), "\"a;b\"");
    assert_eq!(tmux_quote("a\nb"), "\"a\\nb\"");
    assert_eq!(tmux_quote("q\"q"), "\"q\\\"q\"");
    assert_eq!(tmux_quote("\u{1f}"), "\"\\037\"");
}

#[test]
fn tmux_quote_roundtrips_adversarial() {
    for s in NASTY {
        let q = tmux_quote(s);
        assert!(
            !q.chars().any(|c| c.is_control()),
            "raw control char in {q:?}"
        );
        assert_eq!(
            tmux_unquote(&q),
            vec![s.to_string()],
            "input {s:?} quoted {q:?}"
        );
    }
}

#[test]
fn tmux_quote_never_splits_a_line_on_semicolon() {
    let q = tmux_quote("x; kill-server");
    assert_eq!(tmux_unquote(&format!("rename-window -t @1 {q}")).len(), 4);
}

#[test]
fn escape_format_doubles_hash() {
    assert_eq!(escape_format("a#b"), "a##b");
    assert_eq!(escape_format("#{pane_id}"), "##{pane_id}");
    assert_eq!(escape_format("plain"), "plain");
}

#[test]
fn targets() {
    assert_eq!(Target::session("a b").as_str(), "=a b:");
    assert_eq!(Target::session_id(SessionId(1)).as_str(), "$1");
    assert_eq!(Target::window_index("s", 3).as_str(), "=s:3");
    assert_eq!(Target::window(WindowId(5)).as_str(), "@5");
    assert_eq!(Target::pane(PaneId(7)).as_str(), "%7");
}

#[test]
fn new_session_attach_args() {
    assert_eq!(
        cmd::new_session_attach("work", Some((120, 40)), None).argv(),
        ["new-session", "-A", "-s", "work", "-x", "120", "-y", "40"]
    );
    assert_eq!(
        cmd::new_session_attach("a#b", None, Some("/x y")).argv(),
        ["new-session", "-A", "-s", "a##b", "-c", "/x y"]
    );
}

#[test]
fn attach_and_control_attach() {
    assert_eq!(
        cmd::attach_session("w").argv(),
        ["attach-session", "-t", "=w:"]
    );
    assert_eq!(
        cmd::control_attach("w", false).argv(),
        ["-C", "attach-session", "-t", "=w:"]
    );
    assert_eq!(
        cmd::control_attach("w", true).argv(),
        ["-CC", "attach-session", "-t", "=w:"]
    );
    assert_eq!(
        cmd::control_attach("my proj", false).to_shell(),
        "tmux -C attach-session -t '=my proj:'"
    );
}

#[test]
fn version_command() {
    assert_eq!(cmd::tmux_version().to_shell(), "tmux -V");
}

#[test]
fn list_commands_use_fixed_formats() {
    assert_eq!(
        cmd::list_sessions().argv(),
        ["list-sessions", "-F", SESSION_FORMAT]
    );
    assert_eq!(
        cmd::list_windows_all().argv(),
        ["list-windows", "-a", "-F", WINDOW_FORMAT]
    );
    assert_eq!(
        cmd::list_panes_all().argv(),
        ["list-panes", "-a", "-F", PANE_FORMAT]
    );
}

#[test]
fn formats_have_expected_fields() {
    let fields = |f: &str| -> Vec<String> {
        f.split(FIELD_SEP)
            .map(|p| p.trim_start_matches("#{").trim_end_matches('}').to_string())
            .collect()
    };
    assert_eq!(
        fields(SESSION_FORMAT),
        ["session_id", "session_name", "session_attached"]
    );
    assert_eq!(
        fields(WINDOW_FORMAT),
        [
            "session_id",
            "window_id",
            "window_index",
            "window_name",
            "window_active",
            "window_flags"
        ]
    );
    assert_eq!(
        fields(PANE_FORMAT),
        [
            "session_id",
            "session_name",
            "session_attached",
            "window_id",
            "window_index",
            "window_name",
            "window_active",
            "window_flags",
            "pane_id",
            "pane_index",
            "pane_active",
            "pane_current_command",
            "pane_current_path",
            "pane_pid",
            "pane_tty",
            "pane_title",
            "pane_width",
            "pane_height"
        ]
    );
}

#[test]
fn control_line_escapes_separator() {
    let line = cmd::list_panes_all().to_control_line();
    assert!(!line.contains(FIELD_SEP));
    assert!(line.contains("\\037"));
    // and it round-trips to the original argv
    assert_eq!(tmux_unquote(&line), cmd::list_panes_all().argv());
}

#[test]
fn new_window_and_friends() {
    let s = Target::session("my proj");
    assert_eq!(
        cmd::new_window(&s, Some("/home/a b"), Some("w;1")).to_shell(),
        "tmux new-window -t '=my proj:' -c '/home/a b' -n 'w;1'"
    );
    assert_eq!(
        cmd::new_window(&s, None, Some("#{x}")).argv(),
        ["new-window", "-t", "=my proj:", "-n", "##{x}"]
    );
    assert_eq!(
        cmd::new_window(&s, None, None).argv(),
        ["new-window", "-t", "=my proj:"]
    );
    let w = Target::window(WindowId(3));
    assert_eq!(cmd::kill_window(&w).argv(), ["kill-window", "-t", "@3"]);
    assert_eq!(
        cmd::kill_pane(&Target::pane(PaneId(4))).argv(),
        ["kill-pane", "-t", "%4"]
    );
    assert_eq!(cmd::select_window(&w).argv(), ["select-window", "-t", "@3"]);
    assert_eq!(
        cmd::rename_window(&w, "a#b").argv(),
        ["rename-window", "-t", "@3", "--", "a##b"]
    );
    assert_eq!(
        cmd::select_pane(&Target::pane(PaneId(9))).argv(),
        ["select-pane", "-t", "%9"]
    );
    assert_eq!(
        cmd::kill_session(&Target::session("x")).argv(),
        ["kill-session", "-t", "=x:"]
    );
}

#[test]
fn rename_survives_both_quoting_layers() {
    let w = Target::window(WindowId(1));
    for name in NASTY {
        let c = cmd::rename_window(&w, name);
        let via_shell = sh_unquote(&c.to_shell());
        assert_eq!(&via_shell[1..], c.argv());
        assert_eq!(tmux_unquote(&c.to_control_line()), c.argv());
    }
}

#[test]
fn split_window_args() {
    let w = Target::window(WindowId(1));
    assert_eq!(
        cmd::split_window(&w, Direction::Horizontal, None).argv(),
        ["split-window", "-h", "-t", "@1"]
    );
    assert_eq!(
        cmd::split_window(&w, Direction::Vertical, Some("/x#y")).argv(),
        ["split-window", "-v", "-t", "@1", "-c", "/x##y"]
    );
}

#[test]
fn send_keys() {
    let p = Target::pane(PaneId(2));
    assert_eq!(
        cmd::send_keys_literal(&p, "-x; rm").argv(),
        ["send-keys", "-t", "%2", "-l", "--", "-x; rm"]
    );
    assert_eq!(
        cmd::send_keys_named(&p, &["Enter", "C-c", ";"])
            .unwrap()
            .argv(),
        ["send-keys", "-t", "%2", "Enter", "C-c", ";"]
    );
    for bad in ["", "a b", "-l", "\n", "x\"y"] {
        assert!(cmd::send_keys_named(&p, &[bad]).is_err(), "{bad:?}");
    }
    // literal text with newline stays on one control line
    let l = cmd::send_keys_literal(&p, "echo hi\n; kill-server").to_control_line();
    assert!(!l.contains('\n'));
    assert_eq!(tmux_unquote(&l)[5], "echo hi\n; kill-server");
}

#[test]
fn resize_and_capture() {
    let w = Target::window(WindowId(1));
    assert_eq!(
        cmd::resize_window(&w, 100, 30).argv(),
        ["resize-window", "-t", "@1", "-x", "100", "-y", "30"]
    );
    let p = Target::pane(PaneId(1));
    assert_eq!(
        cmd::capture_pane(&p, Some(200)).argv(),
        ["capture-pane", "-p", "-e", "-J", "-t", "%1", "-S", "-200"]
    );
    assert_eq!(
        cmd::capture_pane(&p, None).argv(),
        ["capture-pane", "-p", "-e", "-J", "-t", "%1"]
    );
    assert_eq!(
        cmd::refresh_client_size(100, 30).argv(),
        ["refresh-client", "-C", "100x30"]
    );
}
