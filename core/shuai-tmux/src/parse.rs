//! Parsers for the fixed `-F` formats in [`crate::cmd`].

use std::fmt;

use crate::cmd::FIELD_SEP;
use crate::ids::SessionId;
use crate::topology::{TmuxPane, TmuxSession, TmuxTopology, TmuxWindow};

/// Parse failure with the 1-based line number.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    FieldCount {
        line: usize,
        expected: usize,
        got: usize,
    },
    BadField {
        line: usize,
        field: &'static str,
        value: String,
    },
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::FieldCount {
                line,
                expected,
                got,
            } => write!(f, "line {line}: expected {expected} fields, got {got}"),
            ParseError::BadField { line, field, value } => {
                write!(f, "line {line}: bad {field}: {value:?}")
            }
        }
    }
}

impl std::error::Error for ParseError {}

fn is_octal(b: u8) -> bool {
    (b'0'..=b'7').contains(&b)
}

/// Undo tmux's output sanitising: `\\` -> `\`, `\ooo` -> byte, `\t`/`\n`/`\r`.
/// Unknown or truncated escapes are kept verbatim; invalid UTF-8 is replaced lossily.
pub fn unescape_output(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'\\' || i + 1 >= b.len() {
            out.push(b[i]);
            i += 1;
            continue;
        }
        match b[i + 1] {
            b'\\' => {
                out.push(b'\\');
                i += 2;
            }
            b'n' => {
                out.push(b'\n');
                i += 2;
            }
            b't' => {
                out.push(b'\t');
                i += 2;
            }
            b'r' => {
                out.push(b'\r');
                i += 2;
            }
            c if is_octal(c) && i + 3 < b.len() && is_octal(b[i + 2]) && is_octal(b[i + 3]) => {
                let v = u32::from(c - b'0') * 64
                    + u32::from(b[i + 2] - b'0') * 8
                    + u32::from(b[i + 3] - b'0');
                out.push(v as u8);
                i += 4;
            }
            _ => {
                out.push(b'\\');
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

struct Row<'a> {
    line: usize,
    f: Vec<&'a str>,
}

impl Row<'_> {
    fn text(&self, i: usize) -> String {
        unescape_output(self.f[i])
    }
    fn num(&self, i: usize, field: &'static str) -> Result<u32, ParseError> {
        self.f[i].parse().map_err(|_| self.bad(field, i))
    }
    fn flag(&self, i: usize, field: &'static str) -> Result<bool, ParseError> {
        match self.f[i] {
            "1" => Ok(true),
            "0" => Ok(false),
            _ => Err(self.bad(field, i)),
        }
    }
    fn id<T: std::str::FromStr>(&self, i: usize, field: &'static str) -> Result<T, ParseError> {
        self.f[i].parse().map_err(|_| self.bad(field, i))
    }
    fn bad(&self, field: &'static str, i: usize) -> ParseError {
        ParseError::BadField {
            line: self.line,
            field,
            value: self.f[i].to_string(),
        }
    }
}

/// Split one `-F` output line on [`FIELD_SEP`].
///
/// tmux 3.2/3.3 and 3.6+ print the separator raw, but tmux 3.4/3.5 escape it as the
/// four characters `\037`. Field values are always escaped by tmux (`\` is doubled and
/// control characters become `\ooo`), so a raw `\x1f` never occurs inside a value and
/// an *unescaped* `\037` (preceded by an even number of backslashes) can only be a
/// separator. The one ambiguity left is a value containing a real 0x1f on tmux 3.4/3.5;
/// that yields a wrong field count, which callers reject instead of misparsing.
pub fn split_fields(line: &str) -> Vec<&str> {
    if line.contains(FIELD_SEP) {
        return line.split(FIELD_SEP).collect();
    }
    let bytes = line.as_bytes();
    let mut out = Vec::new();
    let (mut start, mut i) = (0, 0);
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            if bytes[i + 1..].starts_with(b"037") {
                out.push(&line[start..i]);
                i += 4;
                start = i;
                continue;
            }
            // an escape: skip the backslash and the escaped byte (e.g. `\\`, `\t`)
            i += 2;
            continue;
        }
        i += 1;
    }
    out.push(&line[start..]);
    out
}

fn rows(s: &str, expected: usize) -> Result<Vec<Row<'_>>, ParseError> {
    let mut out = vec![];
    for (n, line) in s.split('\n').enumerate() {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.is_empty() {
            continue;
        }
        let f = split_fields(line);
        if f.len() != expected {
            return Err(ParseError::FieldCount {
                line: n + 1,
                expected,
                got: f.len(),
            });
        }
        out.push(Row { line: n + 1, f });
    }
    Ok(out)
}

fn session_of(r: &Row, id: usize, name: usize, att: usize) -> Result<TmuxSession, ParseError> {
    Ok(TmuxSession {
        id: r.id(id, "session_id")?,
        name: r.text(name),
        attached: r.num(att, "session_attached")?,
        windows: vec![],
    })
}

fn window_of(r: &Row, o: usize) -> Result<TmuxWindow, ParseError> {
    Ok(TmuxWindow {
        id: r.id(o, "window_id")?,
        index: r.num(o + 1, "window_index")?,
        name: r.text(o + 2),
        active: r.flag(o + 3, "window_active")?,
        flags: r.text(o + 4),
        panes: vec![],
    })
}

/// Parse `list-sessions -F SESSION_FORMAT` (windows left empty).
pub fn parse_sessions(s: &str) -> Result<Vec<TmuxSession>, ParseError> {
    rows(s, 3)?.iter().map(|r| session_of(r, 0, 1, 2)).collect()
}

/// Parse `list-windows -a -F WINDOW_FORMAT` (panes left empty).
pub fn parse_windows(s: &str) -> Result<Vec<(SessionId, TmuxWindow)>, ParseError> {
    rows(s, 6)?
        .iter()
        .map(|r| Ok((r.id(0, "session_id")?, window_of(r, 1)?)))
        .collect()
}

/// Parse `list-panes -a -F PANE_FORMAT` into the full tree. Sessions and windows keep
/// first-seen order; panes keep line order.
pub fn parse_topology(s: &str) -> Result<TmuxTopology, ParseError> {
    let mut topo = TmuxTopology::default();
    for r in rows(s, 18)? {
        let sess = session_of(&r, 0, 1, 2)?;
        let win = window_of(&r, 3)?;
        let pane = TmuxPane {
            id: r.id(8, "pane_id")?,
            index: r.num(9, "pane_index")?,
            active: r.flag(10, "pane_active")?,
            current_command: r.text(11),
            current_path: r.text(12),
            pid: r.num(13, "pane_pid")?,
            tty: r.text(14),
            title: r.text(15),
            width: r.num(16, "pane_width")?,
            height: r.num(17, "pane_height")?,
        };
        let si = match topo.sessions.iter().position(|x| x.id == sess.id) {
            Some(i) => i,
            None => {
                topo.sessions.push(sess);
                topo.sessions.len() - 1
            }
        };
        let windows = &mut topo.sessions[si].windows;
        let wi = match windows.iter().position(|x| x.id == win.id) {
            Some(i) => i,
            None => {
                windows.push(win);
                windows.len() - 1
            }
        };
        windows[wi].panes.push(pane);
    }
    Ok(topo)
}
