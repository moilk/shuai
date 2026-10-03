//! `tmux -V` parsing and a capability table.
//!
//! Version facts come from tmux's CHANGES file: control mode 1.8, `#{q:}` 2.9,
//! `refresh-client -F no-output` 3.0, `-f` spelling + `pause-after` + `-B` subscriptions
//! 3.2, `%pane-mode-changed`/`%window-pane-changed`/`%client-session-changed`/
//! `%session-window-changed` 2.4. tmux 3.8 switches layouts to JSON only for clients that
//! opt in, so the classic layout format keeps working.

use std::cmp::Ordering;

use crate::cmd::{TmuxCommand, refresh_client_flags};

/// Parsed tmux version. `next-3.7` / `master` are development builds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TmuxVersion {
    pub major: u32,
    pub minor: u32,
    /// Letter suffix of point releases (`3.3a` -> `Some('a')`).
    pub patch: Option<char>,
    /// `next-X.Y` development build: sorts just before release X.Y but is treated as having
    /// X.Y's features.
    pub next: bool,
    /// `tmux master`: assumed newer than everything.
    pub master: bool,
}

impl TmuxVersion {
    /// Parse the output of `tmux -V` (`tmux 3.6`, `tmux 3.3a`, `tmux next-3.7`, `tmux master`).
    pub fn parse(s: &str) -> Option<Self> {
        let s = s.trim();
        let s = s.strip_prefix("tmux").map(str::trim_start).unwrap_or(s);
        if s == "master" {
            return Some(Self {
                major: u32::MAX,
                minor: 0,
                patch: None,
                next: false,
                master: true,
            });
        }
        let (s, next) = match s.strip_prefix("next-") {
            Some(r) => (r, true),
            None => (s, false),
        };
        let (maj, rest) = s.split_once('.')?;
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return None;
        }
        let (min, suffix) = rest.split_at(digits);
        let patch = match suffix.chars().collect::<Vec<_>>()[..] {
            [] => None,
            [c] if c.is_ascii_lowercase() => Some(c),
            _ => return None,
        };
        Some(Self {
            major: maj.parse().ok()?,
            minor: min.parse().ok()?,
            patch,
            next,
            master: false,
        })
    }

    /// `(major, minor)` comparison helper, ignoring patch letters and `next-`.
    pub fn at_least(&self, major: u32, minor: u32) -> bool {
        self.master || (self.major, self.minor) >= (major, minor)
    }
}

impl PartialOrd for TmuxVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for TmuxVersion {
    fn cmp(&self, other: &Self) -> Ordering {
        let key = |v: &Self| {
            (
                v.master,
                v.major,
                v.minor,
                // next-X.Y sorts before X.Y but after the previous release's patches
                !v.next,
                v.patch.map_or(0u32, |c| c as u32),
            )
        };
        key(self).cmp(&key(other))
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
    pub fn for_version(v: &TmuxVersion) -> Self {
        Self {
            control_mode: v.at_least(1, 8),
            no_output: v.at_least(3, 0),
            client_flags_lowercase_f: v.at_least(3, 2),
            pause_after: v.at_least(3, 2),
            subscriptions: v.at_least(3, 2),
            format_quote: v.at_least(2, 9),
            extended_notifications: v.at_least(2, 4),
        }
    }
}

/// Commands to send right after `tmux -C attach` so the connection becomes a
/// notification-only side channel (no `%output`). Empty when unsupported (<3.0): the
/// caller must then discard `%output` itself.
pub fn suppress_output_commands(v: &TmuxVersion) -> Vec<TmuxCommand> {
    let c = Capabilities::for_version(v);
    if !c.no_output {
        return vec![];
    }
    let flag = if c.client_flags_lowercase_f {
        "-f"
    } else {
        "-F"
    };
    vec![refresh_client_flags(flag, "no-output")]
}
