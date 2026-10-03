//! `tmux -V` parsing and a capability table.

use std::cmp::Ordering;

use crate::cmd::TmuxCommand;

/// Parsed tmux version. `next-3.7` / `master` are development builds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TmuxVersion {
    pub major: u32,
    pub minor: u32,
    /// Letter suffix of point releases (`3.3a` -> `Some('a')`).
    pub patch: Option<char>,
    /// `next-X.Y` development build (counts as *older* than release X.Y but we treat as X.Y).
    pub next: bool,
    /// `tmux master`: assumed newer than everything.
    pub master: bool,
}

impl TmuxVersion {
    /// Parse the output of `tmux -V`.
    pub fn parse(_s: &str) -> Option<Self> {
        todo!()
    }
    /// `(major, minor)` comparison helper, ignoring patch letters.
    pub fn at_least(&self, _major: u32, _minor: u32) -> bool {
        todo!()
    }
}

impl PartialOrd for TmuxVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for TmuxVersion {
    fn cmp(&self, _other: &Self) -> Ordering {
        todo!()
    }
}

/// What a given tmux version supports (only features shuai cares about).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capabilities {
    pub control_mode: bool,
    /// `refresh-client -F/-f no-output`.
    pub no_output: bool,
    /// `no-output` spelled `-f` (3.2+); `-F` before.
    pub client_flags_lowercase_f: bool,
    pub pause_after: bool,
    pub subscriptions: bool,
    /// `#{q:...}` format modifier.
    pub format_quote: bool,
    /// `%session-window-changed`, `%window-pane-changed`, ...
    pub extended_notifications: bool,
}

impl Capabilities {
    pub fn for_version(_v: &TmuxVersion) -> Self {
        todo!()
    }
}

/// Commands to send right after `tmux -C attach` so the connection becomes a
/// notification-only side channel (no `%output`). Empty when unsupported (<3.0): the
/// caller must then discard `%output` itself.
pub fn suppress_output_commands(_v: &TmuxVersion) -> Vec<TmuxCommand> {
    todo!()
}
