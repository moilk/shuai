//! `list-clients` parsing and identification of shuai's PTY client.
//!
//! shuai has two tmux clients per host: the PTY client the user types into and the
//! control-mode side channel. Commands issued over the side channel run as *that* client, so
//! `switch-client` must name the PTY client's tty (`switch-client -c TTY`).

use std::fmt;

use crate::cmd::FIELD_SEP;
use crate::ids::SessionId;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxClient {
    pub tty: String,
    pub pid: u32,
    pub session_id: SessionId,
    pub session_name: String,
    pub control_mode: bool,
    /// Unix seconds (`#{client_created}`).
    pub created: u64,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientParseError {
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

impl fmt::Display for ClientParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::FieldCount {
                line,
                expected,
                got,
            } => write!(f, "line {line}: expected {expected} fields, got {got}"),
            Self::BadField { line, field, value } => {
                write!(f, "line {line}: bad {field}: {value:?}")
            }
        }
    }
}

impl std::error::Error for ClientParseError {}

const FIELDS: usize = 8;

/// Parses the output of `list-clients -F CLIENT_FORMAT`. Blank lines are skipped.
pub fn parse_clients(text: &str) -> Result<Vec<TmuxClient>, ClientParseError> {
    let mut out = vec![];
    for (i, raw) in text.lines().enumerate() {
        let line = i + 1;
        if raw.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = raw.split(FIELD_SEP).collect();
        if f.len() != FIELDS {
            return Err(ClientParseError::FieldCount {
                line,
                expected: FIELDS,
                got: f.len(),
            });
        }
        let num = |field: &'static str, v: &str| {
            v.parse::<u64>().map_err(|_| ClientParseError::BadField {
                line,
                field,
                value: v.to_string(),
            })
        };
        out.push(TmuxClient {
            tty: f[0].to_string(),
            pid: num("pid", f[1])? as u32,
            session_id: f[2].parse().map_err(|_| ClientParseError::BadField {
                line,
                field: "session_id",
                value: f[2].to_string(),
            })?,
            session_name: f[3].to_string(),
            control_mode: f[4] == "1",
            created: num("created", f[5])?,
            width: if f[6].is_empty() {
                0
            } else {
                num("width", f[6])? as u32
            },
            height: if f[7].is_empty() {
                0
            } else {
                num("height", f[7])? as u32
            },
        });
    }
    Ok(out)
}

/// The tty of our PTY client among the clients attached to `session`.
///
/// Candidates are non-control clients of the session. The PTY attach is opened right before
/// the control channel, so among several candidates (other devices attached to the same
/// session) the best one is: matching terminal `size`, then created at or before our control
/// client (`control_pid`), then the most recently created.
pub fn pick_pty_client(
    clients: &[TmuxClient],
    session: &str,
    control_pid: Option<u32>,
    size: Option<(u32, u32)>,
) -> Option<String> {
    pick(
        clients.iter().filter(|c| c.session_name == session),
        clients,
        control_pid,
        size,
    )
}

/// Like [`pick_pty_client`] but regardless of the session the client currently shows (after
/// a `switch-client` it no longer sits in the session the side channel attached to).
pub fn pick_pty_client_any_session(
    clients: &[TmuxClient],
    control_pid: Option<u32>,
    size: Option<(u32, u32)>,
) -> Option<String> {
    pick(clients.iter(), clients, control_pid, size)
}

fn pick<'a>(
    candidates: impl Iterator<Item = &'a TmuxClient>,
    all: &[TmuxClient],
    control_pid: Option<u32>,
    size: Option<(u32, u32)>,
) -> Option<String> {
    let control_created = control_pid.and_then(|p| {
        all.iter()
            .find(|c| c.control_mode && c.pid == p)
            .map(|c| c.created)
    });
    candidates
        .filter(|c| !c.control_mode)
        .max_by_key(|c| {
            let size_match = size.is_some_and(|s| s == (c.width, c.height));
            let before = control_created.is_none_or(|cc| c.created <= cc);
            (size_match, before, c.created)
        })
        .map(|c| c.tty.clone())
}
