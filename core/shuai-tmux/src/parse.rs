//! Parsers for the fixed `-F` formats in [`crate::cmd`].

use std::fmt;

use crate::ids::SessionId;
use crate::topology::{TmuxSession, TmuxTopology, TmuxWindow};

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

/// Undo tmux's output sanitising: `\\` -> `\`, `\ooo` -> byte, `\t`/`\n`/`\r` etc.
/// Invalid UTF-8 is replaced lossily.
pub fn unescape_output(_s: &str) -> String {
    todo!()
}

/// Parse `list-sessions -F SESSION_FORMAT` (windows left empty).
pub fn parse_sessions(_s: &str) -> Result<Vec<TmuxSession>, ParseError> {
    todo!()
}

/// Parse `list-windows -a -F WINDOW_FORMAT` (panes left empty).
pub fn parse_windows(_s: &str) -> Result<Vec<(SessionId, TmuxWindow)>, ParseError> {
    todo!()
}

/// Parse `list-panes -a -F PANE_FORMAT` into the full tree.
pub fn parse_topology(_s: &str) -> Result<TmuxTopology, ParseError> {
    todo!()
}
